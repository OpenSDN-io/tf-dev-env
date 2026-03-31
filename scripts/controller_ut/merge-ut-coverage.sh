#!/bin/bash -ex
# Run inside tf-dev-sandbox (DEVENV_TAG): lcov merge + genhtml; publish /output/logs/coverage/.
infos="/in/*.info"
merged="/out/coverage.merged.info"
merged_tmp="${merged}.tmp"
htmlout="/out/coverage-html"
generated_code='/root/contrail/build/*'

rm -rf /in/*
mkdir -p /in
args=""
coverage_url="${LOGS_URL%/}/${STREAM}/logs/coverage/"
coverage_files=$(curl -fsSL "$coverage_url" | sed -n 's/.*href="\([^"#?]*\.info\.gz\)".*/\1/p' | grep -v merged)
for ut_coverage_file in $coverage_files ; do
  url="${coverage_url}${ut_coverage_file}"
  if curl -fsSL "$url" -o "/in/${ut_coverage_file}"; then
    gunzip -f "/in/${ut_coverage_file}"
    args+="-a /in/${ut_coverage_file%.gz} "
  else
    echo "WARN: could not download $url"
    exit 1
  fi
done

rm -rf /out/*
mkdir -p /out

lcov $args -o "$merged" --ignore-errors source,unused
if [[ ! -s "$merged" ]]; then
  echo "ERROR: $merged missing or empty after lcov merge"
  exit 1
fi

if ! lcov --remove "$merged" "$generated_code" -o "$merged_tmp" \
    --ignore-errors source,unused; then
  echo "WARN: lcov --remove build/ failed; publishing unfiltered merge"
  rm -f "$merged_tmp"
else
  mv -f "$merged_tmp" "$merged"
fi
if [[ ! -s "$merged" ]]; then
  echo "ERROR: $merged missing or empty after lcov --remove"
  exit 1
fi

rm -rf "$htmlout"
genhtml_opts=(
  --ignore-errors source
  --legend
  --title "OpenSDN C/C++ coverage (all TARGET_SET jobs)"
)
genhtml "${genhtml_opts[@]}" -o "$htmlout" "$merged"

if [[ ! -f "$htmlout/index.html" ]]; then
  echo "ERROR: genhtml did not produce $htmlout/index.html"
  exit 1
fi

mkdir -p /output/logs/coverage
cp -f "$merged" /output/logs/coverage/
cp -a "$htmlout" /output/logs/coverage/
find /output/logs/coverage -maxdepth 1 -name '*.info' -type f -print0 | xargs -0 -r gzip -f
if [[ -n "${HOST_UID:-}" ]]; then
  chown -R "${HOST_UID}:${HOST_GID}" /output/logs/coverage
fi
echo "INFO: merged coverage → /output/logs/coverage/ ($infos)"
