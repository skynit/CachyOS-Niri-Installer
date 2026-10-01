# 启用一个 DMS 插件，但**不覆盖用户已有的设置**。
#
# 只在还没有 enabled 字段时写入（首次安装），用户之后在设置界面关掉了，重装不会又给打开。
# $plugin 由 --arg 传入。
if ((.[$plugin] // {}) | has("enabled")) then
    .
else
    .[$plugin] = ((.[$plugin] // {}) + {"enabled": true})
end
