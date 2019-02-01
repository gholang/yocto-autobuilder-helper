#!/bin/bash
#
# Build performance test script wrapper
#
# Copyright (c) 2016, Intel Corporation.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms and conditions of the GNU General Public License,
# version 2, as published by the Free Software Foundation.
#
# This program is distributed in the hope it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
#
# This script is a simple wrapper around the actual build performance tester
# script. This script initializes the build environment, runs
# oe-build-perf-test and archives the results.

script=`basename $0`
script_dir=$(realpath $(dirname $0))
archive_dir=~/perf-results/archives

usage () {
cat << EOF
Usage: $script [-h] [-C GIT_REPO]

Optional arguments:
  -h                show this help and exit.
  -a ARCHIVE_DIR    archive results tarball here, give an empty string to
                    disable tarball archiving (default: $archive_dir)
  -C GIT_REPO       commit results into Git
  -d DOWNLOAD_DIR   directory to store downloaded sources in
  -E EMAIL_ADDR     send email report
  -g GLOBALRES_DIR  where to place the globalres file
  -p PUBLISH_DIR    directory to publish into
  -P GIT_REMOTE     push results to a remote Git repository
  -r RESULTS_DIR    directory to store results artefacts in
  -w WORK_DIR       work dir for this script
                    (default: GIT_TOP_DIR/build-perf-test)
EOF
}

get_os_release_var () {
    ( source /etc/os-release; eval echo '$'$1 )
}


# Parse command line arguments
oe_build_perf_test_extra_opts=()
oe_git_archive_extra_opts=()
while getopts "ha:c:C:d:E:g:p:P:r:R:w:x" opt; do
    case $opt in
        h)  usage
            exit 0
            ;;
        a)  mkdir -p "$OPTARG"
            archive_dir=`realpath -s "$OPTARG"`
            ;;
        C)  mkdir -p "$OPTARG"
            results_repo=`realpath -s "$OPTARG"`
            ;;
        d)  mkdir -p "$OPTARG"
            download_dir=`realpath -s "$OPTARG"`
            ;;
        E)  email_to="$OPTARG"
            ;;
        g)  mkdir -p "$OPTARG"
            globalres_dir=`realpath -s "$OPTARG"`
            ;;
        p)  mkdir -p "$OPTARG"
            publish_dir=`realpath -s "$OPTARG"`
            ;;
        P)  oe_git_archive_extra_opts+=("--push" "$OPTARG")
            ;;
        r)  archive_dir=`realpath -s "$OPTARG"`/archive
            results_repo=`realpath -s "$OPTARG"`/archive-repo
            globalres_dir=`realpath -s "$OPTARG"`
            mkdir -p $results_repo $archive_dir
            ;;
        w)  base_dir=`realpath -s "$OPTARG"`
            if [ -n "$base_dir" ]; then
                rm -rf $base_dir/*
            fi
            ;;
        *)  usage
            exit 1
            ;;
    esac
done

# Check positional args
shift "$((OPTIND - 1))"
if [ $# -ne 0 ]; then
    echo "ERROR: No positional args are accepted."
    usage
    exit 1
fi

if [ -n "$email_to" ]; then
    if ! [ -x "$(command -v phantomjs)" ]; then
        echo "ERROR: Sending email needs phantomjs."
        exit 1
    fi
    if ! [ -x "$(command -v optipng)" ]; then
        echo "ERROR: Sending email needs optipng."
        exit 1
    fi
fi

# Open a file descriptor for flock and acquire lock
LOCK_FILE="/tmp/oe-build-perf-test-wrapper.lock"
if ! exec 3> "$LOCK_FILE"; then
    echo "ERROR: Unable to open lock file"
    exit 1
fi
if ! flock -n 3; then
    echo "ERROR: Another instance of this script is running"
    exit 1
fi

echo "Running on `uname -n`"
if ! git_topdir=$(git rev-parse --show-toplevel); then
        echo "The current working dir doesn't seem to be a git clone. Please cd there before running `basename $0`"
        exit 1
fi

cd "$git_topdir"

# Determine name of the current branch
branch=`git symbolic-ref HEAD 2> /dev/null`
# Strip refs/heads/
branch=${branch:11}

# Setup build environment
if [ -z "$base_dir" ]; then
    base_dir="$git_topdir/build-perf-test"
fi
echo "Using working dir $base_dir"

if [ -z "$download_dir" ]; then
    download_dir="$base_dir/downloads"
fi
if [ -z "$globalres_dir" ]; then
    globalres_dir="$base_dir"
fi

timestamp=`date "+%Y%m%d%H%M%S"`
git_rev=$(git rev-parse --short HEAD)  || exit 1
build_dir="$base_dir/build-$git_rev-$timestamp"
results_dir="$base_dir/results-$git_rev-$timestamp"
globalres_log="$globalres_dir/globalres.log"
machine="qemux86"

mkdir -p "$base_dir"
source ./oe-init-build-env $build_dir >/dev/null || exit 1

# Additional config
auto_conf="$build_dir/conf/auto.conf"
echo "MACHINE = \"$machine\"" > "$auto_conf"
echo 'BB_NUMBER_THREADS = "8"' >> "$auto_conf"
echo 'PARALLEL_MAKE = "-j 8"' >> "$auto_conf"
echo "DL_DIR = \"$download_dir\"" >> "$auto_conf"
# Disabling network sanity check slightly reduces the variance of timing results
echo 'CONNECTIVITY_CHECK_URIS = ""' >> "$auto_conf"
# Possibility to define extra settings
if [ -f "$base_dir/auto.conf.extra" ]; then
    cat "$base_dir/auto.conf.extra" >> "$auto_conf"
fi

# Run actual test script
oe-build-perf-test --out-dir "$results_dir" \
                   --globalres-file "$globalres_log" \
                   "${oe_build_perf_test_extra_opts[@]}" \
                   --lock-file "$base_dir/oe-build-perf.lock"

case $? in
    1)  echo "ERROR: oe-build-perf-test script failed!"
        exit 1
        ;;
    2)  echo "NOTE: some tests failed!"
        ;;
esac

if [ -n "$publish_dir" ]; then
    cp -r ${results_dir}/* $publish_dir
fi

# Commit results to git
if [ -n "$results_repo" ]; then
    echo -e "\nArchiving results in $results_repo"
    oe-git-archive \
        --git-dir "$results_repo" \
        --branch-name "{hostname}/{branch}/{machine}" \
        --tag-name "{hostname}/{branch}/{machine}/{commit_count}-g{commit}/{tag_number}" \
        --exclude "buildstats.json" \
        --notes "buildstats/{branch_name}" "$results_dir/buildstats.json" \
        "${oe_git_archive_extra_opts[@]}" \
        "$results_dir"

    # Generate test reports
    sanitized_branch=`echo $branch | tr / _`
    report_txt=`hostname`_${sanitized_branch}_${machine}.txt
    report_html=`hostname`_${sanitized_branch}_${machine}.html
    echo -e "\nGenerating test report"
    oe-build-perf-report -r "$results_repo" > $report_txt
    oe-build-perf-report -r "$results_repo" --html > $report_html

    cp $report_txt $globalres_dir/`hostname`_${sanitized_branch}__$timestamp_$git_rev.txt
    cp $report_html $globalres_dir/`hostname`_${sanitized_branch}_$timestamp_$git_rev.html

    if [ -n "$publish_dir" ]; then
        cp $report_txt $publish_dir/`hostname`_${sanitized_branch}_$timestamp_$git_rev.txt
        cp $report_html $publish_dir/`hostname`_${sanitized_branch}_$timestamp_$git_rev.html
    fi

    # Send email report
    if [ -n "$email_to" ]; then
        echo "Emailing test report"
        os_name=`get_os_release_var PRETTY_NAME`
        "$script_dir"/oe-build-perf-report-email.py --to "$email_to" --subject "Build Perf Test Report for $os_name" --text $report_txt --html $report_html "${OE_BUILD_PERF_REPORT_EMAIL_EXTRA_ARGS[@]}"
    fi
fi

if [ -n "$archive_dir" ]; then
    echo -ne "\n\n-----------------\n"
    echo "Archiving results in $archive_dir"
    mkdir -p "$archive_dir"
    results_basename=`basename "$results_dir"`
    results_dirname=`dirname "$results_dir"`
    tar -czf "$archive_dir/`uname -n`-${results_basename}.tar.gz" -C "$results_dirname" "$results_basename"
fi

rm -rf "$build_dir"
rm -rf "$results_dir"

echo "DONE"
