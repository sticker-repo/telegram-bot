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
        *)
            echo -e "Unknown command: $command"
            ;;
    esac
}
main "$@"