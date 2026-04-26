#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h>
#include <objidl.h>
#include <gdiplus.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

#include "resource.h"

using namespace Gdiplus;

namespace {

constexpr UINT WM_TRAY = WM_APP + 1;
constexpr UINT WM_ADD_TRAY = WM_APP + 2;
constexpr int HOTKEY_ID = 1;
constexpr int MAX_MESSAGES = 26;
constexpr int TIMER_CANCEL_ESC_GUARD = 10;
constexpr int LABEL_RADIUS = 20;
constexpr int LABEL_GAP = 8;
constexpr int LABEL_FONT_PT = 12;

constexpr wchar_t APP_NAME[] = L"消息点点";
constexpr wchar_t WINDOW_CLASS[] = L"MsgDotsNativeWindow";
constexpr wchar_t OVERLAY_CLASS[] = L"MsgDotsNativeOverlay";
constexpr wchar_t SETTINGS_FILE[] = L"settings.ini";
constexpr wchar_t WECHAT_CN[] = L"微信";
constexpr wchar_t WECHAT_EN[] = L"WeChat";

struct Rect {
    int left = 0;
    int top = 0;
    int right = 0;
    int bottom = 0;
};

struct Message {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;
    bool fromSelf = false;
};

struct Bubble {
    int left = 0;
    int right = 0;
    int top = 0;
    int bottom = 0;
    bool fromSelf = false;
};

struct BitmapPixels {
    HBITMAP bitmap = nullptr;
    HDC dc = nullptr;
    uint8_t* pixels = nullptr;
    int width = 0;
    int height = 0;
    int stride = 0;

    BitmapPixels() = default;
    BitmapPixels(const BitmapPixels&) = delete;
    BitmapPixels& operator=(const BitmapPixels&) = delete;
    BitmapPixels(BitmapPixels&& other) noexcept {
        *this = std::move(other);
    }
    BitmapPixels& operator=(BitmapPixels&& other) noexcept {
        if (this == &other) return *this;
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
        bitmap = other.bitmap;
        dc = other.dc;
        pixels = other.pixels;
        width = other.width;
        height = other.height;
        stride = other.stride;
        other.bitmap = nullptr;
        other.dc = nullptr;
        other.pixels = nullptr;
        other.width = 0;
        other.height = 0;
        other.stride = 0;
        return *this;
    }

    ~BitmapPixels() {
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
    }
};

struct HotkeyConfig {
    UINT key = 'D';
    UINT modifiers = MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT;
};

HINSTANCE g_instance = nullptr;
HWND g_main = nullptr;
HWND g_overlay = nullptr;
HHOOK g_keyboardHook = nullptr;
HANDLE g_singleInstance = nullptr;
ULONG_PTR g_gdiplusToken = 0;
bool g_trayAdded = false;
bool g_overlayVisible = false;
bool g_guardEsc = false;
std::vector<Message> g_messages;

std::wstring appDataDir() {
    wchar_t base[MAX_PATH]{};
    DWORD len = GetEnvironmentVariableW(L"APPDATA", base, MAX_PATH);
    std::wstring dir = (len > 0 && len < MAX_PATH) ? base : L".";
    dir += L"\\MsgDots";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

std::wstring settingsPath() {
    return appDataDir() + L"\\" + SETTINGS_FILE;
}

void logLine(const std::wstring& text) {
    std::wstring path = appDataDir() + L"\\msgdots.log";
    HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;

    SYSTEMTIME st{};
    GetLocalTime(&st);
    wchar_t line[1024]{};
    wsprintfW(line, L"%04u-%02u-%02u %02u:%02u:%02u  %s\r\n",
              st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, text.c_str());
    DWORD bytes = 0;
    int utf8Len = WideCharToMultiByte(CP_UTF8, 0, line, -1, nullptr, 0, nullptr, nullptr);
    if (utf8Len > 1) {
        std::string utf8(static_cast<size_t>(utf8Len - 1), '\0');
        WideCharToMultiByte(CP_UTF8, 0, line, -1, utf8.data(), utf8Len, nullptr, nullptr);
        WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &bytes, nullptr);
    }
    CloseHandle(file);
}

std::wstring hotkeyDisplay(const HotkeyConfig& cfg) {
    std::wstring display;
    if (cfg.modifiers & MOD_CONTROL) display += L"Ctrl+";
    if (cfg.modifiers & MOD_ALT) display += L"Alt+";
    if (cfg.modifiers & MOD_SHIFT) display += L"Shift+";
    display.push_back(static_cast<wchar_t>(cfg.key));
    return display;
}

HotkeyConfig loadHotkey() {
    HotkeyConfig cfg;
    std::wstring path = settingsPath();
    wchar_t keyBuf[16]{};
    wchar_t modBuf[16]{};
    GetPrivateProfileStringW(L"hotkey", L"key", L"D", keyBuf, 16, path.c_str());
    GetPrivateProfileStringW(L"hotkey", L"modifiers", L"6", modBuf, 16, path.c_str());
    if (keyBuf[0] >= L'A' && keyBuf[0] <= L'Z') cfg.key = keyBuf[0];
    if (cfg.key == L'Q') cfg.key = L'D';
    cfg.modifiers = static_cast<UINT>(std::wcstoul(modBuf, nullptr, 10)) | MOD_NOREPEAT;
    if ((cfg.modifiers & (MOD_CONTROL | MOD_ALT | MOD_SHIFT)) == 0) {
        cfg.modifiers = MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT;
    }
    if (cfg.key == L'D' && (cfg.modifiers & ~MOD_NOREPEAT) == MOD_CONTROL) {
        cfg.modifiers = MOD_CONTROL | MOD_SHIFT | MOD_NOREPEAT;
    }
    return cfg;
}

void saveHotkey(const HotkeyConfig& cfg) {
    std::wstring path = settingsPath();
    wchar_t keyBuf[2] = { static_cast<wchar_t>(cfg.key), 0 };
    wchar_t modBuf[16]{};
    wsprintfW(modBuf, L"%u", cfg.modifiers & ~MOD_NOREPEAT);
    WritePrivateProfileStringW(L"hotkey", L"key", keyBuf, path.c_str());
    WritePrivateProfileStringW(L"hotkey", L"modifiers", modBuf, path.c_str());
}

bool registerHotkey() {
    UnregisterHotKey(g_main, HOTKEY_ID);
    HotkeyConfig cfg = loadHotkey();
    bool ok = RegisterHotKey(g_main, HOTKEY_ID, cfg.modifiers, cfg.key) != FALSE;
    logLine(ok
        ? L"hotkey registered: " + hotkeyDisplay(cfg)
        : L"hotkey registration failed: " + hotkeyDisplay(cfg) + L" error=" + std::to_wstring(GetLastError()));
    return ok;
}

HWND findWeChatWindow() {
    HWND hwnd = FindWindowW(nullptr, WECHAT_CN);
    if (!hwnd) hwnd = FindWindowW(nullptr, WECHAT_EN);
    return hwnd;
}

BitmapPixels captureWindow(HWND hwnd, const RECT& rect) {
    BitmapPixels out;
    out.width = rect.right - rect.left;
    out.height = rect.bottom - rect.top;
    if (out.width <= 0 || out.height <= 0) return out;

    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = out.width;
    bi.bmiHeader.biHeight = -out.height;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    out.dc = CreateCompatibleDC(nullptr);
    out.bitmap = CreateDIBSection(out.dc, &bi, DIB_RGB_COLORS,
                                  reinterpret_cast<void**>(&out.pixels), nullptr, 0);
    if (!out.dc || !out.bitmap || !out.pixels) return out;
    SelectObject(out.dc, out.bitmap);
    out.stride = out.width * 4;

    if (!PrintWindow(hwnd, out.dc, 2)) {
        HDC screen = GetDC(nullptr);
        BitBlt(out.dc, 0, 0, out.width, out.height, screen, rect.left, rect.top, SRCCOPY);
        ReleaseDC(nullptr, screen);
    }
    return out;
}

int argMax(const int hist[256]) {
    int best = 0;
    int bestIdx = 0;
    for (int i = 0; i < 256; ++i) {
        if (hist[i] > best) {
            best = hist[i];
            bestIdx = i;
        }
    }
    return bestIdx;
}

bool looksLikeNeutralBubbleFill(uint8_t r, uint8_t g, uint8_t b, int bgR, int bgG, int bgB, int delta) {
    int maxv = std::max({ int(r), int(g), int(b) });
    int minv = std::min({ int(r), int(g), int(b) });
    if (maxv - minv > 6 || maxv < 232) return false;
    if (delta < 9 || delta > 42) return false;
    int bgAvg = (bgR + bgG + bgB) / 3;
    int avg = (int(r) + int(g) + int(b)) / 3;
    return std::abs(avg - bgAvg) >= 3;
}

void estimateBackground(const BitmapPixels& bmp, int cropLeft, int cropTop, int cropW, int cropH,
                        int& bgR, int& bgG, int& bgB) {
    int histR[256]{};
    int histG[256]{};
    int histB[256]{};
    int total = cropW * cropH;
    int step = std::max(1, total / 50000);
    for (int idx = 0; idx < total; idx += step) {
        int cy = idx / cropW;
        int cx = idx % cropW;
        const uint8_t* p = bmp.pixels + (cropTop + cy) * bmp.stride + (cropLeft + cx) * 4;
        histB[p[0]]++;
        histG[p[1]]++;
        histR[p[2]]++;
    }
    bgR = argMax(histR);
    bgG = argMax(histG);
    bgB = argMax(histB);
}

std::vector<uint8_t> buildMask(const BitmapPixels& bmp, int cropLeft, int cropTop, int cropW, int cropH,
                               int bgR, int bgG, int bgB) {
    std::vector<uint8_t> mask(static_cast<size_t>(cropW) * cropH);
    for (int y = 0; y < cropH; ++y) {
        const uint8_t* row = bmp.pixels + (cropTop + y) * bmp.stride + cropLeft * 4;
        for (int x = 0; x < cropW; ++x) {
            const uint8_t* p = row + x * 4;
            int delta = std::abs(int(p[2]) - bgR) + std::abs(int(p[1]) - bgG) + std::abs(int(p[0]) - bgB);
            mask[static_cast<size_t>(y) * cropW + x] =
                (delta > 24 || looksLikeNeutralBubbleFill(p[2], p[1], p[0], bgR, bgG, bgB, delta)) ? 1 : 0;
        }
    }

    int edgeMargin = std::min(20, cropW / 40);
    for (int x = 0; x < edgeMargin; ++x) {
        int hits = 0;
        for (int y = 0; y < cropH; ++y) hits += mask[static_cast<size_t>(y) * cropW + x] ? 1 : 0;
        if (double(hits) / std::max(1, cropH) > 0.08) {
            for (int y = 0; y < cropH; ++y) mask[static_cast<size_t>(y) * cropW + x] = 0;
        }
    }
    for (int x = std::max(0, cropW - edgeMargin); x < cropW; ++x) {
        int hits = 0;
        for (int y = 0; y < cropH; ++y) hits += mask[static_cast<size_t>(y) * cropW + x] ? 1 : 0;
        if (double(hits) / std::max(1, cropH) > 0.08) {
            for (int y = 0; y < cropH; ++y) mask[static_cast<size_t>(y) * cropW + x] = 0;
        }
    }
    return mask;
}

std::vector<Rect> findVerticalBands(const std::vector<uint8_t>& mask, int cropW, int cropH) {
    std::vector<uint8_t> rowHas(cropH);
    for (int y = 0; y < cropH; ++y) {
        for (int x = 0; x < cropW; ++x) {
            if (mask[static_cast<size_t>(y) * cropW + x]) {
                rowHas[y] = 1;
                break;
            }
        }
    }

    std::vector<Rect> bands;
    int i = 0;
    while (i < cropH) {
        if (!rowHas[i]) {
            ++i;
            continue;
        }
        int start = i;
        int end = i;
        int gap = 0;
        while (i < cropH) {
            if (rowHas[i]) {
                end = i;
                gap = 0;
            } else if (++gap > 8) {
                break;
            }
            ++i;
        }
        bands.push_back({ 0, start, 0, end });
    }
    return bands;
}

bool looksLikeLeftAvatarRun(int width, int left, int cropW) {
    return left < std::min(150, cropW / 10) && width <= 150;
}

std::vector<Rect> horizontalRuns(const std::vector<uint8_t>& mask, int cropW, int y) {
    std::vector<Rect> runs;
    int start = -1;
    int end = -1;
    for (int x = 0; x < cropW; ++x) {
        if (mask[static_cast<size_t>(y) * cropW + x]) {
            if (start < 0) start = x;
            end = x;
            continue;
        }
        if (start >= 0) {
            runs.push_back({ start, y, end, y });
            start = -1;
        }
    }
    if (start >= 0) runs.push_back({ start, y, end, y });
    return runs;
}

int median(std::vector<int>& values) {
    if (values.empty()) return 0;
    std::sort(values.begin(), values.end());
    return values[values.size() / 2];
}

void medianPatch(const BitmapPixels& bmp, int cropLeft, int cropTop, int cropW, int cropH,
                 int left, int right, int top, int bottom, int& r, int& g, int& b) {
    int cx = (left + right) / 2;
    int cy = (top + bottom) / 2;
    int x0 = std::max(0, cx - 2);
    int x1 = std::min(cropW, cx + 3);
    int y0 = std::max(0, cy - 2);
    int y1 = std::min(cropH, cy + 3);
    std::vector<int> rs, gs, bs;
    for (int y = y0; y < y1; ++y) {
        const uint8_t* row = bmp.pixels + (cropTop + y) * bmp.stride + cropLeft * 4;
        for (int x = x0; x < x1; ++x) {
            const uint8_t* p = row + x * 4;
            bs.push_back(p[0]);
            gs.push_back(p[1]);
            rs.push_back(p[2]);
        }
    }
    r = median(rs);
    g = median(gs);
    b = median(bs);
}

std::vector<Message> detectRecentMessages() {
    HWND wechat = findWeChatWindow();
    if (!wechat) {
        logLine(L"WeChat window not found");
        return {};
    }
    RECT wr{};
    GetWindowRect(wechat, &wr);
    BitmapPixels bmp = captureWindow(wechat, wr);
    if (!bmp.pixels) return {};

    UINT dpi = GetDpiForWindow(wechat);
    double scale = dpi ? double(dpi) / 96.0 : 1.0;
    int cropLeft = int(360 * scale);
    int cropRight = int(bmp.width - 18 * scale);
    int cropTop = int((58 + 4) * scale);
    int cropBottom = int(bmp.height - (130 + 4) * scale);
    if (cropRight <= cropLeft || cropBottom <= cropTop) return {};

    int cropW = cropRight - cropLeft;
    int cropH = cropBottom - cropTop;
    int bgR = 0, bgG = 0, bgB = 0;
    estimateBackground(bmp, cropLeft, cropTop, cropW, cropH, bgR, bgG, bgB);
    std::vector<uint8_t> mask = buildMask(bmp, cropLeft, cropTop, cropW, cropH, bgR, bgG, bgB);
    std::vector<Rect> bands = findVerticalBands(mask, cropW, cropH);

    std::vector<Bubble> bubbles;
    int chatCenterX = cropW / 2;
    for (const Rect& band : bands) {
        int top = band.top;
        int bottom = band.bottom;
        if (bottom - top + 1 < 24) continue;

        Rect best{};
        int bestWidth = 0;
        for (int y = top; y <= bottom; ++y) {
            for (const Rect& run : horizontalRuns(mask, cropW, y)) {
                int width = run.right - run.left + 1;
                if (width < 36 || width > cropW * 0.72) continue;
                if (looksLikeLeftAvatarRun(width, run.left, cropW)) continue;
                if (width > bestWidth) {
                    best = run;
                    bestWidth = width;
                }
            }
        }
        if (bestWidth < 36) continue;

        int midX = (best.left + best.right) / 2;
        if (std::abs(midX - chatCenterX) < cropW * 0.08 && bestWidth < cropW * 0.40) continue;

        int r = 0, g = 0, b = 0;
        medianPatch(bmp, cropLeft, cropTop, cropW, cropH, best.left, best.right, top, bottom, r, g, b);
        bool isGreen = g > r + 6 && g > b + 6;
        bool posRight = best.left > cropW * 0.45 && cropW - 1 - best.right < best.left;
        bubbles.push_back({ best.left, best.right, top, bottom, isGreen || posRight });
    }

    std::sort(bubbles.begin(), bubbles.end(), [](const Bubble& a, const Bubble& b) {
        return a.bottom > b.bottom;
    });

    std::vector<Message> messages;
    for (const Bubble& bubble : bubbles) {
        if (messages.size() >= static_cast<size_t>(MAX_MESSAGES)) break;
        messages.push_back({
            wr.left + cropLeft + bubble.left,
            wr.top + cropTop + bubble.top,
            std::max(1, bubble.right - bubble.left + 1),
            std::max(1, bubble.bottom - bubble.top + 1),
            bubble.fromSelf
        });
    }
    logLine(L"detected bubbles: " + std::to_wstring(messages.size()));
    return messages;
}

void installKeyboardHook();
void uninstallKeyboardHook();

void dismissOverlay() {
    if (g_overlay) DestroyWindow(g_overlay);
    g_overlay = nullptr;
    g_overlayVisible = false;
    uninstallKeyboardHook();
}

void startCancelEscGuard() {
    g_guardEsc = true;
    installKeyboardHook();
    SetTimer(g_main, TIMER_CANCEL_ESC_GUARD, 1000, nullptr);
}

POINT normalizeToVirtualDesktop(POINT pt) {
    int vx = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int vw = std::max(1, GetSystemMetrics(SM_CXVIRTUALSCREEN));
    int vh = std::max(1, GetSystemMetrics(SM_CYVIRTUALSCREEN));
    POINT out{};
    out.x = int(std::round((pt.x - vx) * 65535.0 / std::max(1, vw - 1)));
    out.y = int(std::round((pt.y - vy) * 65535.0 / std::max(1, vh - 1)));
    return out;
}

void postMouse(POINT pt, DWORD down, DWORD up) {
    POINT abs = normalizeToVirtualDesktop(pt);
    INPUT inputs[3]{};
    DWORD common = MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    inputs[0].type = INPUT_MOUSE;
    inputs[0].mi.dx = abs.x;
    inputs[0].mi.dy = abs.y;
    inputs[0].mi.dwFlags = MOUSEEVENTF_MOVE | common;
    inputs[1].type = INPUT_MOUSE;
    inputs[1].mi.dx = abs.x;
    inputs[1].mi.dy = abs.y;
    inputs[1].mi.dwFlags = down | common;
    inputs[2].type = INPUT_MOUSE;
    inputs[2].mi.dx = abs.x;
    inputs[2].mi.dy = abs.y;
    inputs[2].mi.dwFlags = up | common;
    SendInput(3, inputs, sizeof(INPUT));
}

std::vector<HWND> snapshotProcessWindows(DWORD pid) {
    std::vector<HWND> handles;
    struct State {
        DWORD pid;
        std::vector<HWND>* handles;
    } state{ pid, &handles };

    EnumWindows([](HWND hwnd, LPARAM param) -> BOOL {
        auto* state = reinterpret_cast<State*>(param);
        DWORD owner = 0;
        GetWindowThreadProcessId(hwnd, &owner);
        if (owner == state->pid && IsWindowVisible(hwnd)) state->handles->push_back(hwnd);
        return TRUE;
    }, reinterpret_cast<LPARAM>(&state));
    return handles;
}

bool containsHwnd(const std::vector<HWND>& handles, HWND hwnd) {
    return std::find(handles.begin(), handles.end(), hwnd) != handles.end();
}

bool findPopupWindow(DWORD pid, const std::vector<HWND>& baseline, RECT& out) {
    DWORD start = GetTickCount();
    while (GetTickCount() - start < 500) {
        struct State {
            DWORD pid;
            const std::vector<HWND>* baseline;
            RECT best;
            int bestArea = 0;
        } state{ pid, &baseline, {} };

        EnumWindows([](HWND hwnd, LPARAM param) -> BOOL {
            auto* state = reinterpret_cast<State*>(param);
            if (containsHwnd(*state->baseline, hwnd) || !IsWindowVisible(hwnd)) return TRUE;
            DWORD owner = 0;
            GetWindowThreadProcessId(hwnd, &owner);
            if (owner != state->pid) return TRUE;
            RECT rect{};
            if (!GetWindowRect(hwnd, &rect)) return TRUE;
            int w = rect.right - rect.left;
            int h = rect.bottom - rect.top;
            if (w <= 40 || w >= 800 || h <= 60 || h >= 1200) return TRUE;
            int area = w * h;
            if (area > state->bestArea) {
                state->best = rect;
                state->bestArea = area;
            }
            return TRUE;
        }, reinterpret_cast<LPARAM>(&state));

        if (state.bestArea > 0) {
            out = state.best;
            return true;
        }
        Sleep(30);
    }
    return false;
}

POINT secondToLastItemCenter(const RECT& popup) {
    int w = popup.right - popup.left;
    int h = popup.bottom - popup.top;
    double menuH = std::max(40.0, h - 36.0);
    double itemH = std::max(16.0, (menuH - 6.0) / 10.0);
    POINT pt{};
    pt.x = popup.left + w / 2;
    pt.y = int(std::round(popup.top + h - 36.0 - 3.0 - itemH * 1.5));
    pt.y = std::max(popup.top + 3, std::min(pt.y, popup.bottom - 3));
    return pt;
}

void quoteAt(const Message& msg) {
    HWND wechat = findWeChatWindow();
    if (!wechat) return;
    DWORD pid = 0;
    GetWindowThreadProcessId(wechat, &pid);
    std::vector<HWND> baseline = snapshotProcessWindows(pid);
    SetForegroundWindow(wechat);
    Sleep(120);

    POINT center{ msg.x + msg.width / 2, msg.y + msg.height / 2 };
    postMouse(center, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP);

    RECT popup{};
    if (findPopupWindow(pid, baseline, popup)) {
        POINT click = secondToLastItemCenter(popup);
        postMouse(click, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP);
    }
}

LRESULT CALLBACK keyboardProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code >= 0 && (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN)) {
        KBDLLHOOKSTRUCT* kb = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
        if (g_overlayVisible) {
            if (kb->vkCode == VK_ESCAPE) {
                dismissOverlay();
                startCancelEscGuard();
                return 1;
            }
            if (kb->vkCode >= 'A' && kb->vkCode <= 'Z') {
                size_t idx = kb->vkCode - 'A';
                if (idx < g_messages.size()) {
                    Message msg = g_messages[idx];
                    dismissOverlay();
                    quoteAt(msg);
                    return 1;
                }
            }
        } else if (g_guardEsc && kb->vkCode == VK_ESCAPE) {
            return 1;
        }
    }
    return CallNextHookEx(g_keyboardHook, code, wParam, lParam);
}

void installKeyboardHook() {
    if (g_keyboardHook) return;
    g_keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardProc, g_instance, 0);
}

void uninstallKeyboardHook() {
    if (!g_keyboardHook || g_overlayVisible || g_guardEsc) return;
    UnhookWindowsHookEx(g_keyboardHook);
    g_keyboardHook = nullptr;
}

void drawOverlay(HWND hwnd, HDC hdc) {
    RECT client{};
    GetClientRect(hwnd, &client);
    HBRUSH bg = CreateSolidBrush(RGB(1, 2, 3));
    FillRect(hdc, &client, bg);
    DeleteObject(bg);

    int originX = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int originY = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int fontPx = MulDiv(LABEL_FONT_PT, GetDeviceCaps(hdc, LOGPIXELSY), 72);

    Graphics graphics(hdc);
    graphics.SetSmoothingMode(SmoothingModeAntiAlias);
    graphics.SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);

    SolidBrush labelBrush(Color(255, 229, 57, 53));
    SolidBrush textBrush(Color(255, 255, 255, 255));
    FontFamily fontFamily(L"Segoe UI");
    Font font(&fontFamily, static_cast<REAL>(fontPx), FontStyleBold, UnitPixel);
    StringFormat format;
    format.SetAlignment(StringAlignmentCenter);
    format.SetLineAlignment(StringAlignmentCenter);
    format.SetFormatFlags(StringFormatFlagsNoWrap);

    for (size_t i = 0; i < g_messages.size() && i < 26; ++i) {
        const Message& msg = g_messages[i];
        int cx = msg.fromSelf
            ? msg.x - LABEL_RADIUS - LABEL_GAP - originX
            : msg.x + msg.width + LABEL_RADIUS + LABEL_GAP - originX;
        int cy = msg.y + msg.height / 2 - originY;
        RectF circle(
            static_cast<REAL>(cx - LABEL_RADIUS),
            static_cast<REAL>(cy - LABEL_RADIUS),
            static_cast<REAL>(LABEL_RADIUS * 2),
            static_cast<REAL>(LABEL_RADIUS * 2));
        graphics.FillEllipse(&labelBrush, circle);

        wchar_t letter[2] = { static_cast<wchar_t>(L'A' + i), 0 };
        graphics.DrawString(letter, 1, &font, circle, &format, &textBrush);
    }
}

LRESULT CALLBACK overlayProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_PAINT: {
        PAINTSTRUCT ps{};
        HDC hdc = BeginPaint(hwnd, &ps);
        drawOverlay(hwnd, hdc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_DESTROY:
        if (g_overlay == hwnd) g_overlay = nullptr;
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

void showOverlay() {
    if (g_overlayVisible) return;
    logLine(L"hotkey fired");
    g_messages = detectRecentMessages();
    if (g_messages.empty()) {
        logLine(L"no messages detected; overlay not shown");
        return;
    }

    int x = GetSystemMetrics(SM_XVIRTUALSCREEN);
    int y = GetSystemMetrics(SM_YVIRTUALSCREEN);
    int w = GetSystemMetrics(SM_CXVIRTUALSCREEN);
    int h = GetSystemMetrics(SM_CYVIRTUALSCREEN);

    g_overlay = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT,
                                OVERLAY_CLASS, L"", WS_POPUP, x, y, w, h,
                                nullptr, nullptr, g_instance, nullptr);
    if (!g_overlay) return;
    SetLayeredWindowAttributes(g_overlay, RGB(1, 2, 3), 255, LWA_COLORKEY);
    g_overlayVisible = true;
    ShowWindow(g_overlay, SW_SHOWNOACTIVATE);
    UpdateWindow(g_overlay);
    installKeyboardHook();
}

void addTrayIcon() {
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_main;
    nid.uID = 1;
    nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    nid.uCallbackMessage = WM_TRAY;
    nid.hIcon = LoadIconW(g_instance, MAKEINTRESOURCEW(IDI_APP));
    if (!nid.hIcon) nid.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    lstrcpynW(nid.szTip, L"消息点点 - 消息快捷操作", ARRAYSIZE(nid.szTip));
    g_trayAdded = Shell_NotifyIconW(NIM_ADD, &nid) != FALSE;
    if (g_trayAdded) {
        logLine(L"tray icon added");
    } else {
        logLine(L"tray icon add failed: " + std::to_wstring(GetLastError()));
    }
}

void removeTrayIcon() {
    if (!g_trayAdded) return;
    NOTIFYICONDATAW nid{};
    nid.cbSize = sizeof(nid);
    nid.hWnd = g_main;
    nid.uID = 1;
    Shell_NotifyIconW(NIM_DELETE, &nid);
    g_trayAdded = false;
}

void showTrayMenu() {
    POINT pt{};
    GetCursorPos(&pt);
    HMENU menu = CreatePopupMenu();
    HotkeyConfig cfg = loadHotkey();
    std::wstring hotkey = L"快捷键：" + hotkeyDisplay(cfg);
    AppendMenuW(menu, MF_STRING | MF_DISABLED, 0, APP_NAME);
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING | MF_DISABLED, 0, hotkey.c_str());
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 1002, L"使用 Ctrl+Shift+D");
    AppendMenuW(menu, MF_STRING, 1003, L"使用 Ctrl+Alt+D");
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, 1004, L"退出");
    SetForegroundWindow(g_main);
    UINT cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, pt.x, pt.y, 0, g_main, nullptr);
    DestroyMenu(menu);

    if (cmd == 1002 || cmd == 1003) {
        HotkeyConfig next;
        next.key = 'D';
        next.modifiers = MOD_CONTROL | MOD_NOREPEAT;
        if (cmd == 1002) next.modifiers |= MOD_SHIFT;
        if (cmd == 1003) next.modifiers |= MOD_ALT;
        saveHotkey(next);
        registerHotkey();
    } else if (cmd == 1004) {
        PostQuitMessage(0);
    }
}

LRESULT CALLBACK mainProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_CREATE:
        PostMessageW(hwnd, WM_ADD_TRAY, 0, 0);
        registerHotkey();
        return 0;
    case WM_ADD_TRAY:
        addTrayIcon();
        return 0;
    case WM_HOTKEY:
        if (wParam == HOTKEY_ID) showOverlay();
        return 0;
    case WM_TRAY:
        switch (LOWORD(lParam)) {
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU:
        case WM_LBUTTONDBLCLK:
        case WM_LBUTTONUP:
            showTrayMenu();
            break;
        }
        return 0;
    case WM_TIMER:
        if (wParam == TIMER_CANCEL_ESC_GUARD) {
            KillTimer(hwnd, TIMER_CANCEL_ESC_GUARD);
            g_guardEsc = false;
            uninstallKeyboardHook();
        }
        return 0;
    case WM_DESTROY:
        dismissOverlay();
        g_guardEsc = false;
        uninstallKeyboardHook();
        UnregisterHotKey(hwnd, HOTKEY_ID);
        removeTrayIcon();
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    g_instance = instance;
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    GdiplusStartupInput gdiplusStartupInput;
    if (GdiplusStartup(&g_gdiplusToken, &gdiplusStartupInput, nullptr) != Ok) {
        logLine(L"GDI+ startup failed");
        return 1;
    }

    g_singleInstance = CreateMutexW(nullptr, TRUE, L"Local\\MsgDots.SingleInstance");
    if (!g_singleInstance || GetLastError() == ERROR_ALREADY_EXISTS) {
        logLine(L"another instance is already running; exiting");
        if (g_singleInstance) CloseHandle(g_singleInstance);
        return 0;
    }

    WNDCLASSW wc{};
    wc.lpfnWndProc = mainProc;
    wc.hInstance = instance;
    wc.lpszClassName = WINDOW_CLASS;
    RegisterClassW(&wc);

    WNDCLASSW overlay{};
    overlay.lpfnWndProc = overlayProc;
    overlay.hInstance = instance;
    overlay.lpszClassName = OVERLAY_CLASS;
    overlay.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    RegisterClassW(&overlay);

    g_main = CreateWindowExW(0, WINDOW_CLASS, APP_NAME, WS_OVERLAPPED,
                             0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
    if (!g_main) return 1;

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (g_singleInstance) CloseHandle(g_singleInstance);
    if (g_gdiplusToken) GdiplusShutdown(g_gdiplusToken);
    return 0;
}
