#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(git rev-parse --show-toplevel)

INTERVAL_PREFETCH=60
INTERVAL_COMMIT_GRAPH=60
INTERVAL_MIDX=60
INTERVAL_PACK_LOOSE=60

PREFETCH_REF_SPEC='+refs/heads/*'

# prefetch fetches commits from origin remote into refs with `prefetch` prefix
# this way objects database(odb) is populated in the background
# user will only need to update ref and checkout during git-fetch / git-pull
prefetch() {
  git remote --verbose |\
    grep fetch |\
    uniq |\
    while read line ; do
      local remote=$(echo "${line}" | awk '{print $1}')
      local url=$(echo "${line}" | awk '{print $2}')

      git fetch \
          --refmap \
          --prune \
          --prune-tags \
          --quiet \
          ${url} \
          "${PREFETCH_REF_SPEC}:refs/prefetch/${remote}/*";
    done;
}

prefetch_loop() {
  while true; do
    INTERVAL_PREFETCH=$(git config --get 'git-care.prefetch')
    if [[ ${INTERVAL_PREFETCH} -le 0 ]]; then
      exit 0;
    fi

    prefetch || :;

    sleep ${INTERVAL_PREFETCH};
  done;
}

# commit_graph refreshes the commit-graph in a non-disruptive manner
# thus speed up git operations over the commit history i.e. git-log
commit_graph() {
  # Split commit-graph does not work when the full commit-graph file
  # is present. So we should remove it first.
  # Reference:
  # - https://github.com/git/git/blob/cb99a34e23e32ca8e94bafaa9699cfd133a17fd3/t/t5324-split-commit-graph.sh#L336
  if [ -f ${PROJECT_DIR}/.git/objects/info/commit-graph ]; then
    rm -f ${PROJECT_DIR}/.git/objects/info/commit-graph
  fi

  git commit-graph write --reachable --split --no-progress;

  if git commit-graph verify --shallow --no-progress; then
    : # Nothing to do
  else
    # Somebody might broke the commit-graph by force pushing
    # This means we need to remove the old graph and rebuild
    # the entire graph.
    rm -f ${PROJECT_DIR}/.git/objects/info/commit-graphs/commit-graph-chain;
    git commit-graph write --reachable --split --no-progress;
  fi
}

commit_graph_loop() {
  while true; do
    INTERVAL_COMMIT_GRAPH=$(git config --get 'git-care.commit-graph')
    if [[ ${INTERVAL_COMMIT_GRAPH} -le 0 ]]; then
      exit 0;
    fi

    commit_graph || :;

    sleep ${INTERVAL_COMMIT_GRAPH};
  done;
}

_midx_verify_or_rewrite() {
  if git multi-pack-index verify --no-progress; then
    :
  else
    rm -f ${PROJECT_DIR}/.git/objects/pack/multi-pack-index;
    git multi-pack-index write --no-progress;
  fi
}

# _midx_auto_size calculates the --batch-size dynamically
# note that this use 2nd biggest batch to achieve a more consistent
# result than Scalar
_midx_auto_size() {
  local second_biggest_pack=$(
    find ${PROJECT_DIR}/.git/objects/pack/*.pack -type f |\
      xargs stat -f%z |\
      sort -n |\
      tail -2 |\
      head -1
  )

  # Result unit is bytes
  BATCH_SIZE=$(expr ${second_biggest_pack} + 1)
}

# multi_pack_index writes a multi-pack-index file
# which is used to incrementally repack them into bigger packfile.
# Pack files which are repack-ed will be cleanup with `expire`
# Consolidating packfiles helps speed up operations such as git-log
multi_pack_index() {
  git multi-pack-index write --no-progress;
  _midx_verify_or_rewrite

  git multi-pack-index expire --no-progress;
  _midx_verify_or_rewrite

  # Autosizing the --batch-size option
  # If there are less than 2 packs, do a full repack
  # otherwise skip the biggest packfile
  local pack_count=$(find ${PROJECT_DIR}/.git/objects/pack/*.pack -type f | wc -l)
  if [ ${pack_count} -le 2 ]; then
    BATCH_SIZE=0
  else
    _midx_auto_size
  fi

  git multi-pack-index repack --batch-size=${BATCH_SIZE} --no-progress;
  _midx_verify_or_rewrite
}

multi_pack_index_loop() {
  while true; do
    INTERVAL_MIDX=$(git config --get 'git-care.multi-pack-index')
    if [[ ${INTERVAL_MIDX} -le 0 ]]; then
      exit 0;
    fi

    multi_pack_index || :;

    sleep ${INTERVAL_MIDX};
  done;
}

# pack_loose_objects packs all loose objects into a pack file with prefix `loose`
# then clean up all the loose objects which were packed.
#
# This is meant to couple with `multi_pack_index` so that the `loose` packfile is
# eventually re-packed into bigger file and cleaned up.
#
# Note that with this approach, unreachable objects are stored and never prune from
# pack files. This is a tradeoff deliberately made for a smoother client-side experience
#
# If size is a concern, one can always run `git repack -A -d && git prune`. But I dont see
# this is very useful right now.
pack_loose_objects() {
  git prune-packed --quiet;

  local obj_dir_count=$(
    find ${PROJECT_DIR}/.git/objects -type d |\
      grep -Ev '(pack|info|objects|commit-graphs)$' |\
      wc -l
  )
  if [ ${obj_dir_count} -ne 0 ]; then
    find ${PROJECT_DIR}/.git/objects/?? -type f |\
      sed -E "s|^${PROJECT_DIR}/.git/objects/(..)/|\1|" |\
      git pack-objects -q ${PROJECT_DIR}/.git/objects/pack/loose 2>&1 >/dev/null;

    git prune-packed --quiet;
  fi
}

pack_loose_objects_loop() {
  while true; do
    INTERVAL_PACK_LOOSE=$(git config --get 'git-care.pack-loose-objects')
    if [[ ${INTERVAL_PACK_LOOSE} -le 0 ]]; then
      exit 0;
    fi

    pack_loose_objects || :;

    sleep ${INTERVAL_PACK_LOOSE};
  done;
}

# start_git_care starts the background processes
start_git_care() {
  # Run a set of tests to ensure background jobs could
  # run without disruption
  echo '
Running some tests before updating git configs
'
  echo 'Testing prefetch'
  prefetch
  echo 'Testing commit_graph'
  commit_graph
  echo 'Testing pack_loose_objects'
  pack_loose_objects
  echo 'Testing multi_pack_index (this might take a bit of time)'
  multi_pack_index
  echo '
All tests succeed! Updating git configs.
'

  # This is to ensure that multiPackIndex is always used
  # during pack processes.
  git config core.multiPackIndex true

  # This should improve fetch speed since you dont have to
  # unpack objects. But without the multi-pack-index job above,
  # it can flood your repo with many packs. Should be unset
  # at all times unless multi_pack_index is running.
  git config transfer.unpackLimit 1

  # Disable gc because we are handling it by ourselves
  # also a lot of fetches from prefetch could make gc slow
  echo 'Disabling auto-gc'
  git config gc.auto 0

  # Set flags for git-care executions
  git config git-care.enable 1
  git config git-care.prefetch ${INTERVAL_PREFETCH}
  git config git-care.commit-graph ${INTERVAL_COMMIT_GRAPH}
  git config git-care.multi-pack-index ${INTERVAL_MIDX}
  git config git-care.pack-loose-objects ${INTERVAL_PACK_LOOSE}

  prefetch_loop  &
  commit_graph_loop  &
  multi_pack_index_loop  &
  pack_loose_objects_loop  &
}

# stop_git_care stop the background processes
stop_git_care() {
  # Re-enable gc
  echo 'Enabling auto-gc'
  git config --unset gc.auto || :

  # Remove dependency on multi-pack-index
  # as the index could be stale overtime
  git config --unset core.multiPackIndex || :

  # See note in start_git_care
  git config --unset transfer.unpackLimit || :

  # Unset all git-care config
  git config --remove-section git-care || :
}

if [[ $(git config --get 'git-care.enable') -eq 0 ]]; then
  echo 'Starting git-care';
  start_git_care;
  echo 'Started git-care';
  echo '
To monitor operations, you can run
> watch git count-objects -v -H

To toggle git-care, just run it again.
> ./git-care.sh

To force-kill all git-care processes and ignore git config changes. (not recommended)
> kill $(ps aux | grep 'git-care' | grep -v grep | grep -v vim | awk '{print $2}')
'

else
  echo 'Stopping git-care';
  stop_git_care;
  echo 'Stopped git-care';
fi

