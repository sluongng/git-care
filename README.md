# git-care

Health care for your git repository

## What is this

`git-care.sh` is a bash script that handle optimizations and prefetch objects for your busy git repository.
The optimizations are borrowed from [Microsoft's Scalar](https://github.com/microsoft/scalar/) with a few tweaks.

The script is designed in a modular way where user can easily tune each of the optimzation job via editing `.git/config` file under `git-care` section.

The default interval which we run these jobs is 60 seconds which is what I use on a BIG repository (bigger than https://github.com/torvalds/linux). If you are using a smaller repository, do consider to use a bigger sleep interval (i.e. 3600s = 60 minutes)

## Requirements

- Git >2.27.0

- Bash

## Features

- **Pre-Fetch objects**: Pre-fetching objects from upstream to hidden refs to pre-populate your git's Object Database(odb) with upstream objects in the background. This will accelerate your `git fetch` and `git pull`.

- **Commit-graph refresh**: Rebuilding commit-graph split in the background in an incremental fashion with Bloom filter included. Helps accelerate operations require traverse git commit tree (i.e. `git log`)

- **Loose-objects packing**: Fetches and commits are immediately stored as delta compressed packfiles, more optimized for retrieving data as well as storage. Loose-objects are cleaned away after have been packed in a non-disruptive way.

- **Repacking multiple packfiles**: Too many packfiles could lead to slow git operations when finding an objects. We incrementally repack multiple packfiles into a bigger one in the background and then remove the old packfiles. This reduce the number of packfile in a repository thus making git a lot faster.

- **Refresh untracked cache**: Git status relies on untracked cache to keep user up-to-date on the repository status. Keeping this fresh should make `git status` faster and more accurate

- **Fsmonitor Watchman hook**: If you have watchman installed, **git-care** will detect and install the fsmonitor hook that Microsoft folks has contributed upstream. This will help `git status` work a lot faster in bigger repository.

- **Clean up**: Similar to git-gc, various garbage collection is also performed routinely (i.e. worktree, reflogs, packrefs, etc...)

## Why not MSFT Scalar

- Scalar does not support Linux-based OS (only MacOS + Window for now).

- Multi-pack-index repack operations in this script was slightly altered to achieve a more consistent result. This has been ported to upstream Scalar in https://github.com/microsoft/scalar/pull/375 .

- Included Bloom filter in commit-graph and detection for missing Bloom filter.

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

- Multiple projects support: `git-care.sh` spawns multiple processes to support 1 big repo project. Attempt to run this over multiple project will cause an unhealthy amount of processes running in parallel in your machine. A proper task scheduler should be used to manage multiple-projects.

## What next?

This script is pretty much feature completed and tested on MacOS + Centos 7.

I orignally wrote this, based on Scalar optimzation, to support similar optimizations on Linux environments. Bash script provides a quick and easy iteration approach to achieving an Minimum Viable Product. However in order to allow further features improvemnts with user configurations, I might consider re-writting this in Rust / Golang.

- [ ] Rewrite in Golang/Rust (multi-platform languages)
- [ ] User config prefetch RefSpec (choose which refs/branch/tag to prefetch)
- [ ] User config for read-only mirror
- [ ] PostCommit hook to `prepush` (this should go with a serverside script that handle cleanup on prepush refs)
      `pre-push + pre-fetch` together achieve similar effect like Facebook's Eden Commit Cloud.
- [ ] Documentation / Testing

## Ackownledgements

- Most of the works here were inspired by [Derrick Stolee's works](https://github.com/derrickstolee) in upstream git and [MSFT's Scalar](https://github.com/microsoft/scalar)

- This script was wrote to improve the Developer Experience @ ${DAY_JOB}. An internal version of `git-care.sh` is mainained separately with little modifications.
