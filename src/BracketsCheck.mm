// BracketsCheck — macOS port
// Original Windows plugin: "BracketsCheck" (C#/.NET, public domain / Unlicense).
// https://github.com/ (Notepad++ plugin for brackets balancing check)
//
// Scans the current document (whole document or current selection) for balanced
// brackets — round (), square [], curly {}, angular <> — and reports the first
// unbalanced/mismatched one. Each bracket type can be individually enabled or
// disabled from the plugin menu (checkmarks), and the choices persist across
// launches.
//
// The balance-check logic is ported verbatim from the C# Main.cs (stack-based
// single pass, identical type-mismatch rules, identical row/character counting
// where tabs count as 4 columns). Only the platform layer changes:
//   ::SendMessage(scintilla, …)        → nppData._sendMessage(sci, …)
//   System.Windows.Forms.MessageBox    → NSAlert
//   GetPrivateProfileInt/WriteString   → an INI-style key=value file in the
//                                        plugin config dir (NPPM_GETPLUGINSCONFIGDIR)
//   toggleCheckMenuItem                → NPPM_SETMENUITEMCHECK
//
// Faithful-behavior notes:
//  * The original is byte/ANSI based (Marshal.PtrToStringAnsi over the Scintilla
//    buffer). We scan the raw UTF-8 byte buffer, which reproduces the original
//    bracket-detection and column math exactly for ASCII/single-byte text (the
//    intended use — SQL and similar). Bracket chars and \n / \t are all ASCII.
//  * No string/comment awareness — the original scans raw text; so do we.
//  * Reporting is message-box only (no caret jump in the original) — preserved.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <cstring>
#include <string>
#include <vector>

// ── plugin identity / menu layout (matches C# CommandMenuInit) ───────────────
static const char *PLUGIN_NAME = "BracketsCheck";
static const int nbFunc = 7;   // 0 All, 1 Selected, 2 separator, 3..6 toggles

// Menu command indices (mirror the C# SetCommand(index,…) calls)
enum {
    CMD_ALL       = 0,
    CMD_SELECTED  = 1,
    CMD_SEP       = 2,
    CMD_ROUND     = 3,
    CMD_SQUARE    = 4,
    CMD_CURLY     = 5,
    CMD_ANGLE     = 6,
};

namespace {

NppData   nppData;
FuncItem  funcItem[nbFunc];

// Bracket-type toggles (all default ON, as in the C# fields).
bool gCheckRound  = true;
bool gCheckSquare = true;
bool gCheckCurly  = true;
bool gCheckAngle  = true;

// INI section/key names — kept identical to the Windows .ini so a user's
// settings carry over verbatim if the same file is present.
static const char *kSectionName = "WhichBracketTypeMustBeChecked";

// ── platform helpers ────────────────────────────────────────────────────────
NppHandle currentScintilla() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle
         : (which == 1) ? nppData._scintillaSecondHandle
                        : nppData._scintillaMainHandle;
}

intptr_t sci(NppHandle h, uint32_t msg, uintptr_t wp = 0, intptr_t lp = 0) {
    return nppData._sendMessage(h, msg, wp, lp);
}

// Plugin config-dir path for our INI-style settings file.
std::string iniFilePath() {
    char buf[2048] = {0};
    nppData._sendMessage(nppData._nppHandle, NPPM_GETPLUGINSCONFIGDIR,
                         (uintptr_t)sizeof(buf) - 1, (intptr_t)buf);
    @autoreleasepool {
        NSString *dir = [NSString stringWithUTF8String:buf];
        if (dir.length == 0) return std::string();
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
        NSString *file = [dir stringByAppendingPathComponent:@"BracketsCheck.ini"];
        return std::string([file UTF8String]);
    }
}

// Minimal INI: read "key=val" (last wins) under our flat file; we only store the
// four bracket flags, so a flat key=value scan is sufficient and robust. Returns
// `def` when the key is absent. Values "1"/nonzero → true.
int iniGetInt(const std::string &path, const char *key, int def) {
    if (path.empty()) return def;
    @autoreleasepool {
        NSString *p = [NSString stringWithUTF8String:path.c_str()];
        NSString *content = [NSString stringWithContentsOfFile:p
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
        if (!content) return def;
        NSString *k = [NSString stringWithUTF8String:key];
        for (NSString *raw in [content componentsSeparatedByCharactersInSet:
                               [NSCharacterSet newlineCharacterSet]]) {
            NSString *line = [raw stringByTrimmingCharactersInSet:
                              [NSCharacterSet whitespaceCharacterSet]];
            NSRange eq = [line rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            NSString *lk = [[line substringToIndex:eq.location]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([lk caseInsensitiveCompare:k] != NSOrderedSame) continue;
            NSString *lv = [[line substringFromIndex:eq.location + 1]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            return (int)[lv integerValue];
        }
        return def;
    }
}

void writeSettings() {
    std::string path = iniFilePath();
    if (path.empty()) return;
    @autoreleasepool {
        // Re-emit the whole [section] block (only keys we own).
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"[%s]\n", kSectionName];
        [out appendFormat:@"checkRound=%d\n",  gCheckRound  ? 1 : 0];
        [out appendFormat:@"checkSquare=%d\n", gCheckSquare ? 1 : 0];
        [out appendFormat:@"checkCurly=%d\n",  gCheckCurly  ? 1 : 0];
        [out appendFormat:@"checkAngle=%d\n",  gCheckAngle  ? 1 : 0];
        NSString *p = [NSString stringWithUTF8String:path.c_str()];
        [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void loadSettings() {
    std::string path = iniFilePath();
    gCheckRound  = iniGetInt(path, "checkRound",  1) > 0;
    gCheckSquare = iniGetInt(path, "checkSquare", 1) > 0;
    gCheckCurly  = iniGetInt(path, "checkCurly",  1) > 0;
    gCheckAngle  = iniGetInt(path, "checkAngle",  1) > 0;
}

void showAlert(NSString *title, NSString *message) {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.alertStyle = NSAlertStyleInformational;
        a.messageText = title;
        a.informativeText = message;
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

void displayError(int rownumber, int charnumber) {
    // Mirrors C# displayError: "Brackets unbalanced at row {0} and character {1}".
    showAlert(@"Brackets unbalanced",
              [NSString stringWithFormat:@"Brackets unbalanced at row %d and character %d",
                                         rownumber, charnumber]);
}

// ── text retrieval (mirrors C# GetAllText / GetSelectedText / GetSelectionStart)
// We read raw bytes (UTF-8) — the bracket scan operates on bytes, matching the
// original's effective ANSI byte handling.
std::string getAllText(NppHandle h) {
    intptr_t length = sci(h, SCI_GETLENGTH);
    if (length <= 0) return std::string();
    std::vector<char> buf((size_t)length + 1, 0);
    sci(h, SCI_GETTEXT, (uintptr_t)length + 1, (intptr_t)buf.data());
    return std::string(buf.data(), (size_t)length);
}

std::string getSelectedText(NppHandle h) {
    // SCI_GETSELTEXT(0, ptr) returns the selection length; the C# code sized its
    // buffer to the whole-document length, which is always >= selection length.
    intptr_t need = sci(h, SCI_GETSELTEXT, 0, 0);   // includes terminating NUL
    if (need <= 1) return std::string();
    std::vector<char> buf((size_t)need + 1, 0);
    sci(h, SCI_GETSELTEXT, 0, (intptr_t)buf.data());
    return std::string(buf.data());                 // NUL-terminated
}

intptr_t getSelectionStart(NppHandle h) {
    return sci(h, SCI_GETSELECTIONSTART);
}

// ── ported balance-check (verbatim semantics from C# checkBrackets) ──────────
// Returns true if balanced; on the first imbalance it shows the error alert and
// returns false. rownumber/charnumber seed the human-readable position (1-based),
// exactly as the C# overloads do.
bool checkBrackets(const std::string &text, int rownumber, int charnumber) {
    struct BCChar { char charvalue; int rownumber; int charnumber; };
    std::vector<BCChar> stack;   // std::vector used as a LIFO stack

    char c = '\0';
    const size_t n = text.size();

    // for (i=0; i<len; i++, charnumber += c=='\t'?4:1)
    for (size_t i = 0; i < n; ++i, charnumber += (c == '\t' ? 4 : 1)) {
        c = text[i];

        if ((c == '(' && gCheckRound)  ||
            (c == '[' && gCheckSquare) ||
            (c == '{' && gCheckCurly)  ||
            (c == '<' && gCheckAngle)) {
            // open bracket → push
            stack.push_back(BCChar{c, rownumber, charnumber});
        }
        else if ((c == ')' && gCheckRound)  ||
                 (c == ']' && gCheckSquare) ||
                 (c == '}' && gCheckCurly)  ||
                 (c == '>' && gCheckAngle)) {
            // close bracket
            if (!stack.empty()) {
                BCChar bcc_pop = stack.back();
                stack.pop_back();
                char opened = bcc_pop.charvalue;
                if ((c == ')' && opened != '(') ||
                    (c == ']' && opened != '[') ||
                    (c == '}' && opened != '{') ||
                    (c == '>' && opened != '<')) {
                    // wrong type closes → error reported on the OPENING bracket
                    displayError(bcc_pop.rownumber, bcc_pop.charnumber);
                    return false;
                }
            } else {
                // stray closer with empty stack → error on this bracket itself
                displayError(rownumber, charnumber);
                return false;
            }
        }
        else if (c == '\n') {
            ++rownumber;
            charnumber = 0;   // post-increment in the for() makes next char start at 1
        }
    }

    if (!stack.empty()) {
        // an opener never closed → error on the (last-pushed) opening bracket
        BCChar bcc_pop = stack.back();
        stack.pop_back();
        displayError(bcc_pop.rownumber, bcc_pop.charnumber);
        return false;
    }
    return true;
}

// ── commands ─────────────────────────────────────────────────────────────────
void checkBracketsAll() {
    @autoreleasepool {
        NppHandle h = currentScintilla();
        std::string textToCheck = getAllText(h);
        if (checkBrackets(textToCheck, 1, 1)) {
            showAlert(@"Brackets balanced!", @"All brackets in your file are balanced");
        }
    }
}

void checkBracketsSelected() {
    @autoreleasepool {
        NppHandle h = currentScintilla();
        std::string allText      = getAllText(h);
        std::string textToCheck  = getSelectedText(h);
        intptr_t    selStart     = getSelectionStart(h);

        // ATTENTION: DO NOT TRIM (comment preserved from the original).
        // Compute starting row/char from the text before the selection.
        if (selStart < 0) selStart = 0;
        if ((size_t)selStart > allText.size()) selStart = (intptr_t)allText.size();
        std::string before = allText.substr(0, (size_t)selStart);

        // rows = before.Split('\n'); rowcount = rows.Length;
        // charcount = rows[last].Length;  → checkBrackets(text, rowcount, charcount+1)
        int rowcount  = 1;
        int charcount = 0;   // length of the current (last) row before selection
        for (char ch : before) {
            if (ch == '\n') { ++rowcount; charcount = 0; }
            else            { ++charcount; }
        }
        // Note: C# counts '\r' as an ordinary char too (Split('\n') keeps it),
        // so trailing '\r' of a CRLF contributes to charcount — matched here.

        if (checkBrackets(textToCheck, rowcount, charcount + 1)) {
            showAlert(@"Brackets balanced!", @"Selected text in your file have brackets balanced");
        }
    }
}

// Toggle handlers — flip the flag and update the menu checkmark via the host.
void setMenuChecked(int cmdIndex, bool checked) {
    nppData._sendMessage(nppData._nppHandle, NPPM_SETMENUITEMCHECK,
                         (uintptr_t)funcItem[cmdIndex]._cmdID, checked ? 1 : 0);
}

void toggleCheckRound()  { gCheckRound  = !gCheckRound;  setMenuChecked(CMD_ROUND,  gCheckRound);  }
void toggleCheckSquare() { gCheckSquare = !gCheckSquare; setMenuChecked(CMD_SQUARE, gCheckSquare); }
void toggleCheckCurly()  { gCheckCurly  = !gCheckCurly;  setMenuChecked(CMD_CURLY,  gCheckCurly);  }
void toggleCheckAngle()  { gCheckAngle  = !gCheckAngle;  setMenuChecked(CMD_ANGLE,  gCheckAngle);  }

} // namespace

// ── plugin exports (the 5 required C symbols) ────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;

    // Load persisted bracket-type choices before building the menu so the
    // initial checkmarks (FuncItem._init2Check) reflect saved state.
    loadSettings();

    memset(funcItem, 0, sizeof(funcItem));

    strncpy(funcItem[CMD_ALL]._itemName,      "Check Brackets: All text",      NPP_MENU_ITEM_SIZE - 1);
    funcItem[CMD_ALL]._pFunc      = checkBracketsAll;

    strncpy(funcItem[CMD_SELECTED]._itemName, "Check Brackets: Selected text", NPP_MENU_ITEM_SIZE - 1);
    funcItem[CMD_SELECTED]._pFunc = checkBracketsSelected;

    // Separator: empty name + null callback (host renders "---" as a divider).
    strncpy(funcItem[CMD_SEP]._itemName, "---", NPP_MENU_ITEM_SIZE - 1);
    funcItem[CMD_SEP]._pFunc = nullptr;

    strncpy(funcItem[CMD_ROUND]._itemName,  "Check round brackets",  NPP_MENU_ITEM_SIZE - 1);
    funcItem[CMD_ROUND]._pFunc      = toggleCheckRound;
    funcItem[CMD_ROUND]._init2Check = gCheckRound;

    strncpy(funcItem[CMD_SQUARE]._itemName, "Check square brackets", NPP_MENU_ITEM_SIZE - 1);
    funcItem[CMD_SQUARE]._pFunc      = toggleCheckSquare;
    funcItem[CMD_SQUARE]._init2Check = gCheckSquare;

    strncpy(funcItem[CMD_CURLY]._itemName,  "Check curly brackets",  NPP_MENU_ITEM_SIZE - 1);
    funcItem[CMD_CURLY]._pFunc      = toggleCheckCurly;
    funcItem[CMD_CURLY]._init2Check = gCheckCurly;

    strncpy(funcItem[CMD_ANGLE]._itemName,  "Check angle brackets",  NPP_MENU_ITEM_SIZE - 1);
    funcItem[CMD_ANGLE]._pFunc      = toggleCheckAngle;
    funcItem[CMD_ANGLE]._init2Check = gCheckAngle;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = nbFunc; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    switch (n->nmhdr.code) {
        case NPPN_SHUTDOWN:
            // Persist bracket-type choices on quit (mirrors C# PluginCleanUp).
            writeSettings();
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t m, uintptr_t w, intptr_t l) {
    (void)m; (void)w; (void)l; return 1;
}
