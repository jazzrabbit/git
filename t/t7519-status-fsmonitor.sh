#!/bin/sh

test_description='git status with file system watcher'

. ./test-lib.sh

#
# To run the entire git test suite using fsmonitor:
#
# copy t/t7519/fsmonitor-all to a location in your path and then set
# GIT_FSMONITOR_TEST=fsmonitor-all and run your tests.
#

# Note, after "git reset --hard HEAD" no extensions exist other than 'TREE'
# "git update-index --fsmonitor" can be used to get the extension written
# before testing the results.

clean_repo () {
	git reset --hard HEAD &&
	git clean -fd
}

dirty_repo () {
	: >untracked &&
	: >dir1/untracked &&
	: >dir2/untracked &&
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	echo 4 >new &&
	echo 5 >dir1/new &&
	echo 6 >dir2/new
}

write_integration_script () {
	write_script .git/hooks/fsmonitor-test<<-\EOF
	if test "$#" -ne 2
	then
		echo "$0: exactly 2 arguments expected"
		exit 2
	fi
	if test "$1" != 1
	then
		echo "Unsupported core.fsmonitor hook version." >&2
		exit 1
	fi
	printf "untracked\0"
	printf "dir1/untracked\0"
	printf "dir2/untracked\0"
	printf "modified\0"
	printf "dir1/modified\0"
	printf "dir2/modified\0"
	printf "new\0"
	printf "dir1/new\0"
	printf "dir2/new\0"
	EOF
}

test_lazy_prereq UNTRACKED_CACHE '
	{ git update-index --test-untracked-cache; ret=$?; } &&
	test $ret -ne 1
'

test_expect_success 'setup' '
	mkdir -p .git/hooks &&
	: >tracked &&
	: >modified &&
	mkdir dir1 &&
	: >dir1/tracked &&
	: >dir1/modified &&
	mkdir dir2 &&
	: >dir2/tracked &&
	: >dir2/modified &&
	git -c core.fsmonitor= add . &&
	git -c core.fsmonitor= commit -m initial &&
	git config core.fsmonitor .git/hooks/fsmonitor-test &&
	cat >.gitignore <<-\EOF
	.gitignore
	expect*
	actual*
	marker*
	EOF
'

# test that the fsmonitor extension is off by default
test_expect_success 'fsmonitor extension is off by default' '
	test-tool dump-fsmonitor >actual &&
	grep "^no fsmonitor" actual
'

# test that "update-index --fsmonitor" adds the fsmonitor extension
test_expect_success 'update-index --fsmonitor" adds the fsmonitor extension' '
	git update-index --fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	grep "^fsmonitor last update" actual
'

# test that "update-index --no-fsmonitor" removes the fsmonitor extension
test_expect_success 'update-index --no-fsmonitor" removes the fsmonitor extension' '
	git update-index --no-fsmonitor &&
	test-tool dump-fsmonitor >actual &&
	grep "^no fsmonitor" actual
'

cat >expect <<EOF &&
h dir1/modified
H dir1/tracked
h dir2/modified
H dir2/tracked
h modified
H tracked
EOF

# test that "update-index --fsmonitor-valid" sets the fsmonitor valid bit
test_expect_success 'update-index --fsmonitor-valid" sets the fsmonitor valid bit' '
	git update-index --fsmonitor &&
	git update-index --fsmonitor-valid dir1/modified &&
	git update-index --fsmonitor-valid dir2/modified &&
	git update-index --fsmonitor-valid modified &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
H dir1/tracked
H dir2/modified
H dir2/tracked
H modified
H tracked
EOF

# test that "update-index --no-fsmonitor-valid" clears the fsmonitor valid bit
test_expect_success 'update-index --no-fsmonitor-valid" clears the fsmonitor valid bit' '
	git update-index --no-fsmonitor-valid dir1/modified &&
	git update-index --no-fsmonitor-valid dir2/modified &&
	git update-index --no-fsmonitor-valid modified &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
H dir1/tracked
H dir2/modified
H dir2/tracked
H modified
H tracked
EOF

# test that all files returned by the script get flagged as invalid
test_expect_success 'all files returned by integration script get flagged as invalid' '
	write_integration_script &&
	dirty_repo &&
	git update-index --fsmonitor &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/new
H dir1/tracked
H dir2/modified
h dir2/new
H dir2/tracked
H modified
h new
H tracked
EOF

# test that newly added files are marked valid
test_expect_success 'newly added files are marked valid' '
	git add new &&
	git add dir1/new &&
	git add dir2/new &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/new
h dir1/tracked
H dir2/modified
h dir2/new
h dir2/tracked
H modified
h new
h tracked
EOF

# test that all unmodified files get marked valid
test_expect_success 'all unmodified files get marked valid' '
	# modified files result in update-index returning 1
	test_must_fail git update-index --refresh --force-write-index &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

cat >expect <<EOF &&
H dir1/modified
h dir1/tracked
h dir2/modified
h dir2/tracked
h modified
h tracked
EOF

# test that *only* files returned by the integration script get flagged as invalid
test_expect_success '*only* files returned by the integration script get flagged as invalid' '
	write_script .git/hooks/fsmonitor-test<<-\EOF &&
	printf "dir1/modified\0"
	EOF
	clean_repo &&
	git update-index --refresh --force-write-index &&
	echo 1 >modified &&
	echo 2 >dir1/modified &&
	echo 3 >dir2/modified &&
	test_must_fail git update-index --refresh --force-write-index &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

# Ensure commands that call refresh_index() to move the index back in time
# properly invalidate the fsmonitor cache
test_expect_success 'refresh_index() invalidates fsmonitor cache' '
	write_script .git/hooks/fsmonitor-test<<-\EOF &&
	EOF
	clean_repo &&
	dirty_repo &&
	git add . &&
	git commit -m "to reset" &&
	git reset HEAD~1 &&
	git status >actual &&
	git -c core.fsmonitor= status >expect &&
	test_i18ncmp expect actual
'

# test fsmonitor with and without preloadIndex
preload_values="false true"
for preload_val in $preload_values
do
	test_expect_success "setup preloadIndex to $preload_val" '
		git config core.preloadIndex $preload_val &&
		if test $preload_val = true
		then
			GIT_FORCE_PRELOAD_TEST=$preload_val; export GIT_FORCE_PRELOAD_TEST
		else
			unset GIT_FORCE_PRELOAD_TEST
		fi
	'

	# test fsmonitor with and without the untracked cache (if available)
	uc_values="false"
	test_have_prereq UNTRACKED_CACHE && uc_values="false true"
	for uc_val in $uc_values
	do
		test_expect_success "setup untracked cache to $uc_val" '
			git config core.untrackedcache $uc_val
		'

		# Status is well tested elsewhere so we'll just ensure that the results are
		# the same when using core.fsmonitor.
		test_expect_success 'compare status with and without fsmonitor' '
			write_integration_script &&
			clean_repo &&
			dirty_repo &&
			git add new &&
			git add dir1/new &&
			git add dir2/new &&
			git status >actual &&
			git -c core.fsmonitor= status >expect &&
			test_i18ncmp expect actual
		'

		# Make sure it's actually skipping the check for modified and untracked
		# (if enabled) files unless it is told about them.
		test_expect_success "status doesn't detect unreported modifications" '
			write_script .git/hooks/fsmonitor-test<<-\EOF &&
			:>marker
			EOF
			clean_repo &&
			git status &&
			test_path_is_file marker &&
			dirty_repo &&
			rm -f marker &&
			git status >actual &&
			test_path_is_file marker &&
			test_i18ngrep ! "Changes not staged for commit:" actual &&
			if test $uc_val = true
			then
				test_i18ngrep ! "Untracked files:" actual
			fi &&
			if test $uc_val = false
			then
				test_i18ngrep "Untracked files:" actual
			fi &&
			rm -f marker
		'
	done
done

# test that splitting the index dosn't interfere
test_expect_success 'splitting the index results in the same state' '
	write_integration_script &&
	dirty_repo &&
	git update-index --fsmonitor  &&
	git ls-files -f >expect &&
	test-tool dump-fsmonitor >&2 && echo &&
	git update-index --fsmonitor --split-index &&
	test-tool dump-fsmonitor >&2 && echo &&
	git ls-files -f >actual &&
	test_cmp expect actual
'

test_expect_success UNTRACKED_CACHE 'ignore .git changes when invalidating UNTR' '
	test_create_repo dot-git &&
	(
		cd dot-git &&
		mkdir -p .git/hooks &&
		: >tracked &&
		: >modified &&
		mkdir dir1 &&
		: >dir1/tracked &&
		: >dir1/modified &&
		mkdir dir2 &&
		: >dir2/tracked &&
		: >dir2/modified &&
		write_integration_script &&
		git config core.fsmonitor .git/hooks/fsmonitor-test &&
		git update-index --untracked-cache &&
		git update-index --fsmonitor &&
		GIT_TRACE_UNTRACKED_STATS="$TRASH_DIRECTORY/trace-before" \
		git status &&
		test-tool dump-untracked-cache >../before
	) &&
	cat >>dot-git/.git/hooks/fsmonitor-test <<-\EOF &&
	printf ".git\0"
	printf ".git/index\0"
	printf "dir1/.git\0"
	printf "dir1/.git/index\0"
	EOF
	(
		cd dot-git &&
		GIT_TRACE_UNTRACKED_STATS="$TRASH_DIRECTORY/trace-after" \
		git status &&
		test-tool dump-untracked-cache >../after
	) &&
	grep "directory invalidation" trace-before >>before &&
	grep "directory invalidation" trace-after >>after &&
	# UNTR extension unchanged, dir invalidation count unchanged
	test_cmp before after
'

test_done
