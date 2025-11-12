# Contributing

Contributions are welcome. All contributed code will be covered by the Apache License v2 of this project.

## Linting

eth-docker CI uses [pre-commit](https://pre-commit.com/) to lint all code within the repo. Add it to your local
copy with `apt install pre-commit` and `pre-commit install`.

This repo uses a squash-and-merge workflow to avoid extra merge commits. Create a branch for your feature or fix,
and work on this branch, then offer a PR from there.

If you end up working on `main`, you can create an `upstream` remote with
`git remote add upstream https://github.com/ethstaker/eth-docker.git`, and create a git alias with
`git config --global alias.push-clean '!git fetch upstream main && git rebase upstream/main && git push -f'`. You can
then `git push-clean` to your fork before opening a PR.

## Style

Eth Docker loosely follows the Google [style guide](https://google.github.io/styleguide/shellguide.html)

The shell is "bash", with a few exceptions

Indentation is 2 spaces

Avoid `;;&` in `case` statements

Prefer `[[ ]]` over `[ ]`

Prefer `${var}` over `$var`, exception parameters and specials such as `$1,` `$@`, `$?`, &c.

Functions that can be called from outside a script are `function-name`, functions that are meant only for
internal use are `__function_name`. E.g. `prune-besu` or `validator-list`, and `__docompose` or `__call_api`.

External variables as well as variables found in `.env` are `VARIABLE_NAME`

Local variables are `variable_name`

Global variables are `__variable_name`

Assign `$?` to `exitstatus` before checking its value, unless you have a specific reason not to

In the entrypoint scripts, which have very few functions, "local" is interpreted to mean "not used past this block",
and "global" means "we need this again later", particularly for `exec`.
