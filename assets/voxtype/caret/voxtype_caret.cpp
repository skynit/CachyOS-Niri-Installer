#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/instance.h>
#include <fcitx-utils/rect.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/log.h>

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

std::string caretPath() {
    const char *xdg = std::getenv("XDG_RUNTIME_DIR");
    std::string dir = xdg ? xdg : "/tmp";
    dir += "/voxtype";
    ::mkdir(dir.c_str(), 0700);
    return dir + "/caret.json";
}

void writeCaret(bool active, int x, int y, int w, int h, double scale) {
    const auto now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    char buf[256];
    std::snprintf(buf, sizeof(buf),
        "{\"active\":%s,\"x\":%d,\"y\":%d,\"w\":%d,\"h\":%d,\"scale\":%.3f,\"ts\":%lld}\n",
        active ? "true" : "false", x, y, w, h, scale,
        static_cast<long long>(now));
    const std::string path = caretPath();
    const std::string tmp = path + ".tmp";
    if (FILE *f = std::fopen(tmp.c_str(), "w")) {
        std::fputs(buf, f);
        std::fclose(f);
        std::rename(tmp.c_str(), path.c_str());
    }
}

} // namespace

class VoxtypeCaretAddon : public fcitx::AddonInstance {
public:
    explicit VoxtypeCaretAddon(fcitx::AddonManager *manager)
        : instance_(manager->instance()) {
        using namespace fcitx;
        handlers_.emplace_back(instance_->watchEvent(
            EventType::InputContextCursorRectChanged,
            EventWatcherPhase::PostInputMethod,
            [](Event &event) {
                auto &ice = static_cast<InputContextEvent &>(event);
                auto *ic = ice.inputContext();
                if (!ic) return;
                const auto &r = ic->cursorRect();
                // 忽略“无光标”的 0x0 事件，保留上一个有效位置；
                // 否则它在录音开始前一刻会把好坐标覆盖掉，OSD 只能退回固定位置。
                if (r.width() <= 0 && r.height() <= 0) {
                    return;
                }
                writeCaret(true, r.left(), r.top(), r.width(), r.height(),
                           ic->scaleFactor());
            }));
        handlers_.emplace_back(instance_->watchEvent(
            EventType::InputContextFocusOut,
            EventWatcherPhase::PostInputMethod,
            [](Event &) { writeCaret(false, 0, 0, 0, 0, 1.0); }));
        handlers_.emplace_back(instance_->watchEvent(
            EventType::InputContextDestroyed,
            EventWatcherPhase::PostInputMethod,
            [](Event &) { writeCaret(false, 0, 0, 0, 0, 1.0); }));
    }

private:
    fcitx::Instance *instance_;
    std::vector<std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>>> handlers_;
};

class VoxtypeCaretFactory : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new VoxtypeCaretAddon(manager);
    }
};

FCITX_ADDON_FACTORY(VoxtypeCaretFactory);
