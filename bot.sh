#!/bin/bash

# for debug
# set -x

# needed envs:
# BOT_TOKEN, ADMIN_CHAT_ID, STICKER_DIR, REPO_URL, CURL_OPTION, MATRIX_AUTH_TOKEN, MATRIX_WEBP_ROOM_ID

ADMIN_CHAT_IDS=("$ADMIN_CHAT_ID")
declare -A MESSAGE_MAP  # Map to track sent messages: "chat_id,message_id,sticker_set_name" -> report_message_id

# STICKER_DIR="/app/repo/s1"
STICKER_INFO_DIR="$STICKER_DIR/info"
STICKER_FILES_DIR="$STICKER_DIR/files"

read -r -a curl_opts <<< "$CURL_OPTION"

initialize() {
    ssh-keyscan github.com >> /root/.ssh/known_hosts

    if [ -d "$STICKER_DIR/.git" ]; then
        cd $STICKER_DIR
        git pull
    else
        git clone --filter=blob:none --sparse $REPO_URL $STICKER_DIR
        cd $STICKER_DIR
        git sparse-checkout set --no-cone '/*' '!files'
    fi

    mkdir -p "$STICKER_INFO_DIR"
    mkdir -p "$STICKER_FILES_DIR"
}

garbage_collection() {
    rm -rf "$STICKER_DIR/.git"

    git clone --filter=blob:none --sparse $REPO_URL $STICKER_DIR
    cd $STICKER_DIR
    git sparse-checkout set --no-cone '/*' '!files'
    
    mkdir -p "$STICKER_INFO_DIR"
    mkdir -p "$STICKER_FILES_DIR"
}

update_index() {
    local set_name="$1"
    local ext="$2"
    local stickers="$3"

    if [ ! -f "$STICKER_DIR/thumbnails.json" ]; then
        echo "{}" > "$STICKER_DIR/thumbnails.json"
    fi

    thumbnails=$(cat "$STICKER_DIR/thumbnails.json")
    thumbnails=$(echo "$thumbnails" | jq -c --arg set_name "$set_name" --arg ext "$ext" '.[$ext] |= (. + [$set_name] | unique)')
    echo "$thumbnails" > "$STICKER_DIR/thumbnails.json"

    emoji_index=$(cat "$STICKER_DIR/emoji_index.json")
    for sticker in $stickers; do
        file_unique_id=$(echo "$sticker" | jq -r '.file_unique_id')
        st_ext=$(echo "$sticker" | jq -r '.extension')
        file_path="$set_name/$file_unique_id.$st_ext"
        emoji=$(echo "$sticker" | jq -r '.emoji')
        emoji_index=$(echo "$emoji_index" | jq -c --arg file_path "$file_path" --arg emoji "$emoji" '.[$emoji] |= (. + [$file_path] | unique)')
    done
    echo "$emoji_index" > "$STICKER_DIR/emoji_index.json"
    rm "$STICKER_DIR/emoji_index.json.gz"
    gzip -k "$STICKER_DIR/emoji_index.json"
}

# a bit of duplicate code, but it keeps the data in memory to be faster
reindex() {
    echo "Starting reindex"
    thumbnails='{}'
    emoji_index='{}'

    for file in $STICKER_INFO_DIR/*.json; do
        # echo "\t Processing file: $file"
        set_name=$(cat "$file" | jq -r '.name')
        th_ext=$(cat "$file" | jq -r '.thumbnail_extension')
        thumbnails=$(echo "$thumbnails" | jq -c --arg set_name "$set_name" --arg ext "$th_ext" '.[$ext] |= (. + [$set_name])') # no need to check unique

        stickers=$(cat "$file" | jq -c '.stickers[]')
        for sticker in $stickers; do
            file_unique_id=$(echo "$sticker" | jq -r '.file_unique_id')
            st_ext=$(echo "$sticker" | jq -r '.extension')
            file_path="$set_name/$file_unique_id.$st_ext"
            emoji=$(echo "$sticker" | jq -r '.emoji')
            emoji_index=$(echo "$emoji_index" | jq -c --arg file_path "$file_path" --arg emoji "$emoji" '.[$emoji] |= (. + [$file_path] | unique)')
        done
    done
    
    echo "Saving new index files"
    echo "$thumbnails" > "$STICKER_DIR/thumbnails.json"
    echo "$emoji_index" > "$STICKER_DIR/emoji_index.json"
    rm "$STICKER_DIR/emoji_index.json.gz"
    gzip -k "$STICKER_DIR/emoji_index.json"
}

add_pack_to_matrix() {
    local set_name="$1"
    local ext="$2"
    if [[ "$ext" == "webp" ]]; then
        echo
        echo "Adding webp sticker pack '$set_name' to matrix room"
        local event=$(jq '
            def ext_to_mimetype:
                ascii_downcase |
                if . == "png" then "image/png"
                elif . == "jpg" or . == "jpeg" then "image/jpeg"
                elif . == "webp" then "image/webp"
                elif . == "webm" then "video/webm"
                elif . == "gif" then "image/gif"
                elif . == "tgs" then "video/tgs"
                else null
                end;

            . as $data |
            (
                if ($data.sticker_type | tostring | contains("emoji")) then
                    "https://t.me/addemoji/\($data.name)"
                else
                    "https://t.me/addstickers/\($data.name)"
                end
            ) as $link |
            {
                images: (
                    [$data.stickers | to_entries[] | select(.value.premium_animation == null)] |
                    map(
                    .key as $idx |
                    .value as $sticker |
                    {
                        ($idx | tostring): {
                        url: "mxc://mtx.sticker-repo.workers.dev/s1-\($data.name)-\($sticker.file_unique_id)-\($sticker.extension)",
                        body: $sticker.emoji,
                        info: ($sticker.extension | ext_to_mimetype | if . then {mimetype: .} else empty end)
                        }
                    }
                    ) |
                    add // {}
                ),
                pack: {
                    display_name: $data.name,
                    attribution: "[sticker-repo.github.io] Original pack at \($link)",
                    usage: ["sticker", "emoticon"]
                }
            }
            ' "$STICKER_INFO_DIR/$set_name.json")
        curl "${curl_opts[@]}" -X PUT \
            "https://matrix.org/_matrix/client/v3/rooms/$MATRIX_WEBP_ROOM_ID/state/im.ponies.room_emotes/$set_name" \
            -H "Authorization: Bearer $MATRIX_AUTH_TOKEN" \
            -H "Content-Type: application/json" \
            -d "$event"
    fi
}

add_pack_to_matrix_for_all_webps() {
    echo "Start adding webp stickers to the room"

    jq -r '.webp[]' "$STICKER_DIR/thumbnails.json" | while read set_name; do
        add_pack_to_matrix "$set_name" "webp"
        sleep 10s
    done
}

update_repo() {
    local sticker_set_name="$1"

    git pull
    git add --all --sparse
    git commit -m "add sticker set '$sticker_set_name'"
    git push
    git sparse-checkout set --no-cone '/*' '!files'
}

# Function to check if the sticker set info exists and if it needs to be updated
needs_update() {
    local set_name="$1"
    local info_file="$STICKER_INFO_DIR/$set_name.json"

    if [[ -f "$info_file" ]]; then
        local timestamp=$(jq -r '.last_sticker_info_download' "$info_file")
        echo "$timestamp"
        return 1  # No update needed

        # last_sticker_info_download_timestamp=$(jq -r '.last_sticker_info_download' "$info_file")
        # current_timestamp=$(date +%s)
        
        # # Check if last download was over 15 days ago
        # if (( (current_timestamp - last_sticker_info_download_timestamp) < 1296000 )); then
        #     return 1  # No update needed
        # fi
    fi
    
    return 0  # Update needed
}

send_message() {
    local text="$1"
    local chat_id="$2"
    local reply_to_message_id="$3"
    local sticker_set_name="$4"
    local clear_after="${5:-false}"
    local parse_mode="${6:-}"
    
    local map_key="${chat_id},${reply_to_message_id},${sticker_set_name}"
    local report_message_id="${MESSAGE_MAP[$map_key]}"
    
    if [[ -n "$report_message_id" ]]; then
        # Edit existing message
        local data="chat_id=$chat_id&message_id=$report_message_id&text=$text"
        if [[ -n "$parse_mode" ]]; then
            data="$data&parse_mode=$parse_mode"
        fi
        local response=$(curl "${curl_opts[@]}" -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/editMessageText" -d "$data")
    else
        # Send new message
        local data="chat_id=$chat_id&text=$text"
        if [[ -n "$parse_mode" ]]; then
            data="$data&parse_mode=$parse_mode"
        fi
        if [[ -n "$reply_to_message_id" && "$reply_to_message_id" != "null" ]]; then
            data="$data&reply_to_message_id=$reply_to_message_id"
        fi
        local response=$(curl "${curl_opts[@]}" -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d "$data")
        
        # Extract and store the new message ID
        local new_message_id=$(echo "$response" | jq -r '.result.message_id // empty')
        if [[ -n "$new_message_id" ]]; then
            MESSAGE_MAP[$map_key]="$new_message_id"
        fi
    fi
    
    if [[ "$clear_after" == "true" ]]; then
        unset 'MESSAGE_MAP[$map_key]'
    fi
}

download_sticker_set_info() {
    local set_name="$1"
    response=$(curl "${curl_opts[@]}" -s "https://api.telegram.org/bot$BOT_TOKEN/getStickerSet?name=$set_name")

    if [[ $(echo "$response" | jq -r '.ok') == "true" ]]; then
        echo "$response" | jq -c '.result + {last_sticker_info_download: now | floor}' > "$STICKER_INFO_DIR/$set_name.json"
        return 0
    else
        echo "Error: $(echo "$response" | jq -r .description)"
        return 1
    fi
}

download_file() {
    local url="$1"
    local file_name="$2"

    curl "${curl_opts[@]}" -s -o "$file_name" "$url"
}

handle_sticker() {
    local sticker_set_name="$1"
    local chat_id="$2" # requester user
    local message_id="$3"
    local force_download="${4:-false}"

    last_timestamp=$(needs_update "$sticker_set_name")
    needs_update_result=$?
    if [[ $needs_update_result -ne 0 ]] && [[ "$force_download" != true ]]; then
        # No update needed
        local readable_date=$(date -d @"$last_timestamp" '+%Y-%m-%d %H:%M:%S')
        local msg="Sticker set <a href=\"https://sticker-repo.github.io/pack/$sticker_set_name\">$sticker_set_name</a> is already downloaded (last updated: $readable_date). Use <i>'force download link'</i> if it's necessary to update it."
        send_message "$msg" "$chat_id" "$message_id" "$sticker_set_name" true HTML
        return
    fi

    # Download the sticker set information
    if ! download_sticker_set_info "$sticker_set_name"; then
        send_message "Error in downloading set '$sticker_set_name'" true
        return
    fi

    send_message "Got sticker set info for '$sticker_set_name'" "$chat_id" "$message_id" "$sticker_set_name"
    
    # Create a directory for the sticker set
    mkdir -p "$STICKER_FILES_DIR/$sticker_set_name"

    # Read sticker set info from JSON file
    set_info=$(cat "$STICKER_INFO_DIR/$sticker_set_name.json")
    stickers=$(echo "$set_info" | jq -c '.stickers[]')

    # Download each sticker
    for sticker in $stickers; do
        file_id=$(echo "$sticker" | jq -r '.file_id')
        file_unique_id=$(echo "$sticker" | jq -r '.file_unique_id')
        file_path=$(curl "${curl_opts[@]}" -s "https://api.telegram.org/bot$BOT_TOKEN/getFile?file_id=$file_id" | jq -r '.result.file_path')
        extension="${file_path##*.}"
        set_info=$(echo "$set_info" | jq --arg unique_id "$file_unique_id" --arg ext "$extension" '.stickers |= map(if .file_unique_id == $unique_id then . + {extension: $ext} else . end)')
        download_file "https://api.telegram.org/file/bot$BOT_TOKEN/$file_path" "$STICKER_FILES_DIR/$sticker_set_name/$file_unique_id.$extension"
    done

    # Download the thumbnail if it exists
    # thumb_file_id=$(echo "$set_info" | jq -r 'if .thumbnail.file_id then .thumbnail.file_id 
    #                   elif .stickers[0].thumbnail.file_id then .stickers[0].thumbnail.file_id  # <--- this may be not tgs for animated packs
    #                   else .stickers[0].file_id end')
    thumb_file_id=$(echo "$set_info" | jq -r 'if .thumbnail.file_id then .thumbnail.file_id 
                    else .stickers[0].file_id end')
    if [[ "$thumb_file_id" != "null" ]]; then
        file_path=$(curl "${curl_opts[@]}" -s "https://api.telegram.org/bot$BOT_TOKEN/getFile?file_id=$thumb_file_id" | jq -r '.result.file_path')
        extension="${file_path##*.}"
        set_info=$(echo "$set_info" | jq --arg ext "$extension" '. + {thumbnail_extension: $ext}')
        download_file "https://api.telegram.org/file/bot$BOT_TOKEN/$file_path" "$STICKER_FILES_DIR/$sticker_set_name/thumbnail.$extension"
        send_message "Indexing '$sticker_set_name'" "$chat_id" "$message_id" "$sticker_set_name"
        update_index "$sticker_set_name" "$extension" "$stickers"
        add_pack_to_matrix "$sticker_set_name" "$extension"
    fi

    # Update last download timestamp
    set_info=$(echo "$set_info" | jq -c '. + {last_file_download: now | floor}')

    echo "$set_info" > "$STICKER_INFO_DIR/$sticker_set_name.json"

    local msg="Downloaded all stickers for set <a href=\"https://sticker-repo.github.io/pack/$sticker_set_name\">$sticker_set_name</a>"
    send_message "$msg" "$chat_id" "$message_id" "$sticker_set_name" true HTML

    update_repo "$sticker_set_name"
}

start_bot() {
    echo "bot started"

    # Bot update loop
    offset=0
    while true; do
        response=$(curl "${curl_opts[@]}" -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$offset&timeout=120")
        offset=$(echo "$response" | jq '.result | map(.update_id) | max + 1')

        # Iterate over each update in the response
        echo "$response" | jq -c '.result[]' | while read -r update; do
            chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
            message_id=$(echo "$update" | jq -r '.message.message_id // empty')
            message_text=$(echo "$update" | jq -r '.message.text // empty')

            if [[ "${ADMIN_CHAT_IDS[@]}" =~ "$chat_id" ]]; then
                # Check for sticker message
                sticker_set_name=$(echo "$update" | jq -r '.message.sticker.set_name // empty')
                if [[ -n "$sticker_set_name" ]]; then
                    send_message "Sticker set '$sticker_set_name'" "$chat_id" "$message_id" "$sticker_set_name"
                    handle_sticker "$sticker_set_name" "$chat_id" "$message_id"
                elif [[ $message_text =~ ^force\ download\ link(.*) ]]; then
                    # Get the rest of the message excluding "download link"
                    links="${BASH_REMATCH[1]}"

                    # Use a loop to find and process all links
                    while [[ $links =~ t\.me/(addemoji|addstickers)/([a-zA-Z0-9\\-\_]+) ]]; do
                        sticker_set_name="${BASH_REMATCH[2]}"

                        send_message "Sticker set '$sticker_set_name' [force-download]" "$chat_id" "$message_id" "$sticker_set_name"
                        handle_sticker "$sticker_set_name" "$chat_id" "$message_id" true
                        
                        # Remove the processed link from links
                        links=${links/${BASH_REMATCH[0]}/}
                    done
                else
                    links="$message_text"
                    while [[ $links =~ t\.me/(addemoji|addstickers)/([a-zA-Z0-9\\-\_]+) ]]; do
                        sticker_set_name="${BASH_REMATCH[2]}"

                        send_message "Sticker set '$sticker_set_name'" "$chat_id" "$message_id" "$sticker_set_name"
                        handle_sticker "$sticker_set_name" "$chat_id" "$message_id"
                        
                        # Remove the processed link from links
                        links=${links/${BASH_REMATCH[0]}/}
                    done
                fi                
            fi
        done
        sleep 1
    done
}
