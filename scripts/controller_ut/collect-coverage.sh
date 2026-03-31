#!/bin/bash -e
logs_path="/output/logs"
cov_dir="$logs_path/coverage"
mkdir -p "$cov_dir"
fail=0
cov_raw="$cov_dir/coverage.raw.info"
cov_info="$cov_dir/coverage.info"
lcov_log="$cov_dir/lcov.log"

coverage_remove_dirs=(
  '/usr/*' '/opt/*' '*/third_party/*'
  "${HOME}/contrail/<stdout>" '*<stdout>*'
  '*/test/*' '*/tests/*'
  '*/gtest/*' '*/gmock/*'
)

lcov_capture_dirs=" -d $HOME/contrail/build/debug -d $HOME/contrail/build/third_party"
lcov --capture $lcov_capture_dirs --base-directory "$HOME/contrail" --ignore-errors source,gcov \
  --output-file "$cov_raw" >>"$lcov_log" 2>&1

if [[ -s "$cov_raw" ]]; then
  lcov --remove "$cov_raw" "${coverage_remove_dirs[@]}" -o "$cov_info" \
    --ignore-errors unused >>"$lcov_log" 2>&1 || cp -f "$cov_raw" "$cov_info"
fi
