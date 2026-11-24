#!/bin/sh
set -eu
mkdir -p "$TAKE/cli/src" "$TAKE/cli/tests"
cd "$TAKE/cli"
git init -q -b main
printf '# Tiny CLI\n' > README.md
printf '[package]\nname = "tiny-cli"\n' > Cargo.toml
printf 'mod args;\nfn main() {}\n' > src/main.rs
printf '// TODO: parse flags\n' > src/args.rs
printf '// TODO: test help output\n' > tests/help.rs
for command in init build check run test fmt docs clean; do
    mkdir -p "src/commands/$command"
    for module in args config output; do
        printf '// %s %s\n' "$command" "$module" > "src/commands/$command/$module.rs"
    done
    printf '// TODO: cover %s errors\n' "$command" > "tests/${command}_test.rs"
done
export CLICOLOR_FORCE=1
printf '\033[2J\033[H'
command_line() {
    printf '\033[38;5;114m~/cli\033[0m \033[38;5;81m❯\033[0m %s\n' "$1"
}
command_line 'eza --tree'
eza --tree --color=always
printf '\n'
command_line 'rg -n TODO'
rg --color=always -n TODO
printf '\n'
command_line 'git status --short'
git -c color.status=always status --short
exec env PS1='~/cli ❯ ' /bin/sh -i
