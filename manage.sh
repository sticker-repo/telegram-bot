source bot.sh
main() {
    initialize
    local command="$1"
    case "$command" in
        start_bot)
            start_bot
            ;;
        reindex)
            reindex
            ;;
        add_pack_to_matrix_for_all_webps)
            add_pack_to_matrix_for_all_webps
            ;;
        *)
            echo -e "Unknown command: $command"
            ;;
    esac
}
main "$@"
