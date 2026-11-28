#!/bin/sh
# Explicit public asset boundary. Templates, tools and config are never payloads.
website_static_files() {
	printf '%s\n' favicon.ico main.js manual.css manual.js opensearch.xml style.css testing.html
}

website_public_files() {
	website_static_files
	printf '%s\n' index.html manual.html Manual.md
}

website_stage_assets() (
	set -eu
	root=$1 destination=$2
	mkdir -p "$destination"
	for name in $(website_static_files); do
		file="$root/website/public/$name"
		[ -f "$file" ] && [ ! -L "$file" ] || {
			printf 'Missing or unsafe website asset: %s\n' "$file" >&2
			exit 1
		}
		cp "$file" "$destination/$name"
	done
)
