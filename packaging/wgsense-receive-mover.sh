#!/bin/zsh
set -u

source_dir="$1"
destination_dir="$2"

/bin/mkdir -p "$destination_dir"
/bin/sleep 1

/usr/bin/find "$source_dir" -maxdepth 1 -type f ! -name '.*' -print0 | while IFS= read -r -d '' file; do
    # LocalSend writes directly to the final filename. Move only after its file
    # descriptor is closed so a slow transfer can never land partially.
    if /usr/sbin/lsof -t -- "$file" >/dev/null 2>&1; then
        continue
    fi

    filename="${file:t}"
    stem="${filename:r}"
    extension="${filename:e}"
    target="$destination_dir/$filename"
    suffix=2
    while [[ -e "$target" ]]; do
        if [[ -n "$extension" && "$extension" != "$filename" ]]; then
            target="$destination_dir/$stem ($suffix).$extension"
        else
            target="$destination_dir/$filename ($suffix)"
        fi
        (( suffix += 1 ))
    done
    # A rename would preserve root ownership from the system daemon. Copy into
    # a hidden user-owned file first, then publish it atomically.
    temporary="$destination_dir/.wgsense-receive-$PPID-$RANDOM.partial"
    if /bin/cp "$file" "$temporary"; then
        /bin/chmod 0644 "$temporary"
        /bin/mv "$temporary" "$target"
        /bin/rm -f "$file"
    else
        /bin/rm -f "$temporary"
    fi
done
