# git-care

Health care for your git repository

## What is this

`git-care.sh` is a bash script that handle optimizations and prefetch objects for your busy git repository.
The optimizations are borrowed from [Microsoft's Scalar](https://github.com/microsoft/scalar/) with a few tweaks.

The script is designed in a modular way where user can easily tune each of the optimzation job via editing `.git/config` file under `git-care` section.

The default interval which we run these jobs is 60 seconds which is what I use on a BIG repository (bigger than https://github.com/torvalds/linux). If you are using a smaller repository, do consider to use a bigger sleep interval (i.e. 3600s = 60 minutes)

## Requirements

- Git >2.26.0. May work with 2.25.0 and earlier but I have yet tested, best to stay on higher version as I do plan to turn on Bloom filter feature coming in 2.27.0.
- Bash

## Why not MSFT Scalar

- Scalar does not support Linux-based OS (only MacOS + Window for now).
- Multi-pack-index repack operations in this script was slightly altered to achieve a more consistent result.

## What is missing in git-care

- No support for GVFS
- No support for sparse-checkout and partial-clone (though this could be used together with a partial-clone repo)

## Caveats

Similar to Scalar optimization, there are some caveats to these optimizations approach:

- You are downloading all branches. Some workflow does not require users to contains all branches on their local copy so it might be a waste to fetch all branches in the background. I intentionally left the ref spec to be a variable that could be updated by user before running so that they can choose which ref to pre-fetch.

- You are **NOT** removing un-reachable objects. In wokflows which have users `git push --force` a lot, many git objects will become loose and unreachable from any branches. In standard approach, these will be cleaned up with `git gc`, but with `git-care.sh` and Scalar, these objects are kept delta compressed in pack files. So its a good idea to occasionally run `git repack -A -d && git prune` manually to remove these loose objects.
  In truth, these loose objects after delta-compressed are not much compare to the total size of your repo, so it should be perfectly ok to just leave it in.

- `git-care.sh` is designed to be a toggling scripts, which leverages git config to be control flags. This means that when you turn off `git-care.sh`, only the flags are removed and not the processes. The processes will turn themselves off within a minute interval, after they detect that relevant config has been removed. But this also means that you should **NOT** turn off -> turn on `git-care.sh` too quickly.
  I hope I could improve this limitation in the future when I refactor this into a different language.

- Repack limit: Scalar has a cap to packing loose objects and repacking multiple packs. This due to the nature of working with the Microsoft Office repository to be way too big and slow. With `git-care.sh`, I dont ignore the biggest packfile when repacking as well as put no loose objects count cap when packing loose objects, but one should be able to add such `if else` condition in easily if needed (it's bash script).

## What next?

This script is pretty much feature completed and tested on MacOS + Centos 7.

I orignally wrote this, based on Scalar optimzation, to support similar optimizations on Linux environments. Bash script provides a quick and easy iteration approach to achieving an Minimum Viable Product. However in order to allow further features improvemnts with user configurations, I might consider re-writting this in Rust / Golang.

- [ ] Rewrite in Golang/Rust (multi-platform languages)
- [ ] User config prefetch RefSpec (choose which refs/branch/tag to prefetch)
- [ ] User config for read-only mirror
- [ ] PostCommit hook to `prepush` (this should go with a serverside script that handle cleanup on prepush refs)
      `pre-push + pre-fetch` together achieve similar effect like Facebook's Eden Commit Cloud.
- [ ] Documentation / Testing
