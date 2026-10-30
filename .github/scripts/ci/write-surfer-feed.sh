#!/usr/bin/env bash
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}"
: "${RUN_ID:?RUN_ID must be set}"
: "${SURFER_USER:?SURFER_USER must be set}"
: "${SURFER_TOKEN:?SURFER_TOKEN must be set}"

mkdir -p "$RUNNER_TEMP/feed-results"
for file in publication/results/*.tsv; do
  arch=${file##*/}; arch=${arch%.tsv}
  mkdir -p "$RUNNER_TEMP/feed-results/build-results-$arch"
  cp "$file" "$RUNNER_TEMP/feed-results/build-results-$arch/results.tsv"
done

feed_url=https://repo.osowoso.org/_webdav/feed.xml
feed_file="$RUNNER_TEMP/feed.xml"
download_body="$RUNNER_TEMP/feed-download.body"
upload_body="$RUNNER_TEMP/feed-upload.body"
echo "::group::Download existing RSS feed"
if download_result=$(curl --silent --show-error --connect-timeout 15 --max-time 120 \
  --user "${SURFER_USER}:${SURFER_TOKEN}" --output "$download_body" \
  --write-out '%{http_code} %{time_total}' "$feed_url"); then
  set -- $download_result
  http_code=$1
  elapsed=$2
  echo "WebDAV GET returned HTTP $http_code in ${elapsed}s"
else
  curl_rc=$?
  echo "::error::RSS feed WebDAV GET failed (curl exit $curl_rc)"
  [ ! -s "$download_body" ] || cat "$download_body"
  exit "$curl_rc"
fi
case "$http_code" in
  200) mv "$download_body" "$feed_file" ;;
  404)
    echo "::notice::No existing feed.xml (HTTP 404); generating an initial feed"
    rm -f "$download_body"
    ;;
  *)
    echo "::error::RSS feed WebDAV GET returned unexpected HTTP $http_code"
    [ ! -s "$download_body" ] || cat "$download_body"
    exit 1
    ;;
esac
echo "::endgroup::"

echo "::group::Generate RSS feed"
python3 extra/src/gen-feed.py update "$feed_file" "$RUNNER_TEMP/feed-results" "$RUN_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" extra/srcpkgs
echo "::endgroup::"

echo "::group::Upload updated RSS feed"
if upload_result=$(curl --silent --show-error --fail-with-body --connect-timeout 15 --max-time 120 \
  --user "${SURFER_USER}:${SURFER_TOKEN}" --output "$upload_body" \
  --write-out '%{http_code} %{time_total}' --upload-file "$feed_file" "$feed_url"); then
  set -- $upload_result
  http_code=$1
  elapsed=$2
else
  curl_rc=$?
  echo "::error::RSS feed WebDAV PUT failed (curl exit $curl_rc)"
  [ ! -s "$upload_body" ] || cat "$upload_body"
  exit "$curl_rc"
fi
case "$http_code" in
  2[0-9][0-9]) echo "WebDAV PUT succeeded: HTTP $http_code in ${elapsed}s" ;;
  *)
    echo "::error::RSS feed WebDAV PUT returned unexpected HTTP $http_code"
    [ ! -s "$upload_body" ] || cat "$upload_body"
    exit 1
    ;;
esac
echo "::endgroup::"
