# Shell completion

Tab-completion for `symphony`'s verbs (bash and zsh):
`init check up logs status stop down add config projects version help`.

Every verb except `projects`, `version` and `help` takes a `<name>` argument,
completed from the project directories under `./projects` — `_example` is
excluded, since it is a template rather than a real project. `up` also
completes `--publish` once a flag-shaped word is being typed.

Both scripts run their project-name lookup relative to `$PWD`, which matches
how `symphony` itself resolves `projects/<name>/` — run completion from
inside a checkout, same as the command it completes.

## Bash

```bash
# this session only
source completions/symphony.bash

# every new shell
echo 'source /path/to/symphony-launcher/completions/symphony.bash' >> ~/.bashrc

# system-wide (if your distro sources /etc/bash_completion.d)
sudo cp completions/symphony.bash /etc/bash_completion.d/symphony
```

## Zsh

```zsh
# this session only
source completions/symphony.zsh

# every new shell
echo 'source /path/to/symphony-launcher/completions/symphony.zsh' >> ~/.zshrc

# or drop it on your $fpath as a compdef function (rename without the .zsh
# extension, e.g. to `_symphony`) and let `compinit` autoload it.
```

Both scripts complete `symphony` and `./symphony` by name; if you invoke the
launcher some other way (a symlink, an alias), add a `complete`/`compdef`
line for that name alongside the ones already in the script.

The verb and project-name logic is a maintained static copy in each script.
If `symphony` gains, renames or drops a verb, update `usage()` there first,
then mirror the change in both `symphony.bash` and `symphony.zsh` (each file
has a comment pointing back here).
