if status is-interactive
    starship init fish | source
    zoxide init fish | source

    alias ls='eza --group-directories-first --icons=auto'
    alias ll='eza -lah --group-directories-first --icons=auto'
    alias tree='eza --tree --icons=auto'
    alias cd='z'
end
