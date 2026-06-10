import ArgumentParser
import Foundation

// ── Shell choice enum ────────────────────────────────────────────────────────

/// The shells supported by `completion` and `setup`.
public enum ShellChoice: String, ExpressibleByArgument, CaseIterable {
    case bash, zsh, fish
}

// ── Verbatim completion-script literals ─────────────────────────────────────
// Copied byte-for-byte from the Python source (remctl:6410-6949).
// Raw multiline string literals preserve every $, \, ", backtick exactly.
// Trailing newline inside each literal is intentional (Python triple-quoted strings
// include the newline before the closing ''').

public enum CompletionScripts {
    public static let zsh: String = #"""
#compdef remctl
_remctl() {
    local -a commands=(
        'lists:List all iCloud reminder lists'
        'smart-lists:Inspect Reminders smart lists'
        'templates:Inspect saved Reminders templates'
        'template-info:Show a saved Reminders template'
        'show:Show reminders in a list'
        'add:Add a reminder'
        'done:Complete a reminder'
        'undone:Uncomplete a reminder'
        'edit:Edit a reminder'
        'delete:Delete a reminder'
        'search:Search reminders'
        'today:Due today + overdue'
        'upcoming:Next N days'
        'overdue:All overdue reminders'
        'flagged:Flagged reminders'
        'urgent:Urgent reminders'
        'flag:Flag a reminder'
        'unflag:Unflag a reminder'
        'tags:List all tags'
        'subtasks:Show subtasks'
        'info:Full detail view'
        'sections:Show sections'
        'sharees:Show people available for assignment in a shared list'
        'stats:Statistics'
        'link:Get deep links'
        'open:Open in Reminders.app'
        'export:Export reminders'
        'import:Import reminders'
        'list-symbols:List official Reminders list symbols'
        'list-create:Create a new list'
        'smart-list-create:Create a private custom smart list'
        'smart-list-edit:Edit a private custom smart list'
        'smart-list-delete:Delete a private custom smart list'
        'template-create:Create a private Reminders template from an entire list'
        'template-apply:Create a list from a saved Reminders template'
        'template-delete:Delete a saved Reminders template'
        'list-edit:Edit private list appearance'
        'list-pin:Pin a list or smart list in Reminders'
        'list-unpin:Unpin a list or smart list in Reminders'
        'list-rename:Rename a list'
        'list-delete:Delete a list'
        'onboard:Prompt for macOS permissions and verify readiness'
        'doctor:Diagnose setup and runtime issues'
        'setup:Install shell completions'
        'permissions:Open guided macOS permission helper'
        'completion:Generate shell completions'
    )
    case "$words[2]" in
        show)
            _arguments \
                '--list-id[Show list by stable numeric ID]:id:' \
                '--completed[Include completed reminders]' \
                '--via-eventkit[Limited read-only EventKit fallback; no numeric ids or private metadata]' \
                '(-v --verbose)'{-v,--verbose}'[Verbose output]' \
                '--json[JSON output]'
            return
            ;;
        search)
            _arguments \
                '--completed[Include completed reminders]' \
                '--via-eventkit[Limited read-only EventKit fallback; no numeric ids or private metadata]' \
                '(-v --verbose)'{-v,--verbose}'[Verbose output]' \
                '--json[JSON output]'
            return
            ;;
        today)
            _arguments \
                '--no-overdue[Exclude overdue reminders]' \
                '--via-eventkit[Limited read-only EventKit fallback; no numeric ids or private metadata]' \
                '(-v --verbose)'{-v,--verbose}'[Verbose output]' \
                '--json[JSON output]'
            return
            ;;
        upcoming)
            _arguments \
                '--via-eventkit[Limited read-only EventKit fallback; no numeric ids or private metadata]' \
                '(-v --verbose)'{-v,--verbose}'[Verbose output]' \
                '--json[JSON output]'
            return
            ;;
        templates)
            _arguments \
                '--json[JSON output]'
            return
            ;;
        template-info)
            _arguments \
                '--template-id[Read by numeric template ID]:id:' \
                '--json[JSON output]'
            return
            ;;
        add)
            _arguments \
                '--private[Use unsupported private ReminderKit metadata writes]' \
                '--section[Assign to existing section]:section:' \
                '--section-id[Assign to section by stable ID]:section-id:' \
                '--new-section[Create and assign to new section]:section:' \
                '--subtask[Add private subtask title or JSON object]:subtask:' \
                '--image[Add private image attachment]:path:_files' \
                '--assign[Assign to shared-list user]:sharee:' \
                '--unassign[Clear existing assignment]' \
                '--grocery[Auto-categorize in a Groceries list]' \
                '--urgent[Set private urgent state]' \
                '--no-urgent[Clear private urgent state]' \
                '--early-reminder[Set Early Reminder delta, e.g. 15m, 1h, clear]:delta:' \
                '--url[URL, web rich link with --private]:url:' \
                '(-t --tags)'{-t,--tags}'[Tags, synced with --private]:tags:' \
                '(-l --list)'{-l,--list}'[Target list]:list:' \
                '--list-id[Target list by stable numeric ID]:id:' \
                '(-d --due)'{-d,--due}'[Due date]:due:' \
                '(-p --priority)'{-p,--priority}'[Priority]:priority:(high medium low)' \
                '(-f --flag)'{-f,--flag}'[Flag reminder]' \
                '--recurrence[Recurrence rule]:recurrence:' \
                '--alarm[Alarm]:alarm:' \
                '--json[JSON output]'
            return
            ;;
        edit)
            _arguments \
                '--private[Use unsupported private ReminderKit metadata writes]' \
                '--section[Assign to existing section]:section:' \
                '--section-id[Assign to section by stable ID]:section-id:' \
                '--new-section[Create and assign to new section]:section:' \
                '--subtask[Add private subtask title or JSON object]:subtask:' \
                '--image[Add private image attachment]:path:_files' \
                '--assign[Assign to shared-list user]:sharee:' \
                '--unassign[Clear existing assignment]' \
                '--grocery[Auto-categorize in the reminder Groceries list]' \
                '--flagged[Set real private flag]' \
                '--no-flagged[Clear real private flag]' \
                '--urgent[Set private urgent state]' \
                '--no-urgent[Clear private urgent state]' \
                '--early-reminder[Set Early Reminder delta, e.g. 15m, 1h, clear]:delta:' \
                '--location-title[Location alarm title]:title:' \
                '--latitude[Location alarm latitude]:latitude:' \
                '--longitude[Location alarm longitude]:longitude:' \
                '--radius[Location alarm radius meters]:radius:' \
                '--proximity[Location alarm trigger]:proximity:(arriving leaving)' \
                '--title[New title]:title:' \
                '(-l --list)'{-l,--list}'[Move to list]:list:' \
                '--list-id[Move to list by stable numeric ID]:id:' \
                '--url[URL, web rich link with --private]:url:' \
                '(-t --tags)'{-t,--tags}'[Synced tags with --private]:tags:' \
                '(-n --notes)'{-n,--notes}'[Notes]:notes:' \
                '(-d --due)'{-d,--due}'[Due date or clear]:due:' \
                '(-p --priority)'{-p,--priority}'[Priority]:priority:(high medium low none)' \
                '--recurrence[Recurrence rule]:recurrence:' \
                '--alarm[Alarm]:alarm:' \
                '--json[JSON output]'
            return
            ;;
        done)
            _arguments \
                '--date[Set completion date]:date:' \
                '--json[JSON output]'
            return
            ;;
        sharees)
            _arguments \
                '--list-id[Shared list by stable numeric ID]:id:' \
                '--json[JSON output]'
            return
            ;;
        doctor)
            _arguments \
                '--for-agent[Print agent-focused context and TCC guidance]' \
                '--json[JSON output]'
            return
            ;;
        link)
            _arguments \
                '(-l --list)'{-l,--list}'[Get links for active reminders in list]:list:' \
                '--list-id[Get links for active reminders in list by stable numeric ID]:id:' \
                '--completed[Include completed reminders]' \
                '--json[JSON output]'
            return
            ;;
        export)
            _arguments \
                '(-l --list)'{-l,--list}'[Export only this list]:list:' \
                '--list-id[Export only this list by stable numeric ID]:id:' \
                '--format[Export format]:format:(json csv)' \
                '--json[JSON output]'
            return
            ;;
        list-symbols)
            _arguments \
                '--html[Write a standalone HTML preview contact sheet]:path:_files' \
                '--preview[Generate and open the HTML preview contact sheet]' \
                '--json[JSON output]'
            return
            ;;
        smart-list-create)
            _arguments \
                '--private[Use private ReminderKit smart-list creation]' \
                '--color[Smart-list color name or #RRGGBB]:color:' \
                '--symbol[Official Reminders list symbol]:symbol:' \
                '--emoji[Private Reminders emoji badge]:emoji:' \
                '--flagged[Filter to flagged reminders]' \
                '--priority[Priority filter]:priority:(high medium low)' \
                '--match[Match all or any filters]:match:(all any)' \
                '--tags[Selected tag filter, comma-separated; # prefix optional]:tags:' \
                '--tag-match[Selected tag matching mode]:match:(all any)' \
                '--any-tag[Filter to reminders with any tag]' \
                '--date[Date filter]:date:(any today)' \
                '--date-on[On date]:date:' \
                '--date-before[Before date]:date:' \
                '--date-after[After date]:date:' \
                '--date-range[Date range START,END]:range:' \
                '--time[Time filter]:time:(morning afternoon evening night)' \
                '--include-list[Include one list]:list:' \
                '--include-list-id[Include numeric list ID]:id:' \
                '--vehicle[Vehicle filter]:vehicle:(connected)' \
                '--location-title[Location title]:title:' \
                '--latitude[Latitude]:latitude:' \
                '--longitude[Longitude]:longitude:' \
                '--radius[Radius meters]:radius:' \
                '--proximity[Location proximity]:proximity:(enter leave arriving leaving)' \
                '--filter-json[Raw official filter JSON or @path]:json:' \
                '--json[JSON output]'
            return
            ;;
        smart-list-edit)
            _arguments \
                '--private[Use private ReminderKit smart-list editing]' \
                '--smart-list-id[Edit by numeric smart-list ID]:id:' \
                '--color[Smart-list color name or #RRGGBB]:color:' \
                '--symbol[Official Reminders list symbol]:symbol:' \
                '--emoji[Private Reminders emoji badge]:emoji:' \
                '--flagged[Filter to flagged reminders]' \
                '--priority[Priority filter]:priority:(high medium low)' \
                '--match[Match all or any filters]:match:(all any)' \
                '--tags[Selected tag filter, comma-separated; # prefix optional]:tags:' \
                '--tag-match[Selected tag matching mode]:match:(all any)' \
                '--any-tag[Filter to reminders with any tag]' \
                '--date[Date filter]:date:(any today)' \
                '--date-on[On date]:date:' \
                '--date-before[Before date]:date:' \
                '--date-after[After date]:date:' \
                '--date-range[Date range START,END]:range:' \
                '--time[Time filter]:time:(morning afternoon evening night)' \
                '--include-list[Include one list]:list:' \
                '--include-list-id[Include numeric list ID]:id:' \
                '--vehicle[Vehicle filter]:vehicle:(connected)' \
                '--location-title[Location title]:title:' \
                '--latitude[Latitude]:latitude:' \
                '--longitude[Longitude]:longitude:' \
                '--radius[Radius meters]:radius:' \
                '--proximity[Location proximity]:proximity:(enter leave arriving leaving)' \
                '--filter-json[Raw official filter JSON or @path]:json:' \
                '--json[JSON output]'
            return
            ;;
        smart-list-delete)
            _arguments \
                '--private[Use private ReminderKit smart-list deletion]' \
                '--smart-list-id[Delete by numeric smart-list ID]:id:' \
                '--force[Skip confirmation prompt]' \
                '--json[JSON output]'
            return
            ;;
        template-create)
            _arguments \
                '--from-list[Source list name]:list:' \
                '--from-list-id[Source list numeric ID]:id:' \
                '--include-completed[Include completed reminders]' \
                '--private[Use private ReminderKit template creation]' \
                '--json[JSON output]'
            return
            ;;
        template-apply)
            _arguments \
                '--template-id[Apply by numeric template ID]:id:' \
                '--private[Use private ReminderKit template application]' \
                '--json[JSON output]'
            return
            ;;
        template-delete)
            _arguments \
                '--template-id[Delete by numeric template ID]:id:' \
                '--private[Use private ReminderKit template deletion]' \
                '--force[Skip confirmation prompt]' \
                '--json[JSON output]'
            return
            ;;
        list-create)
            _arguments \
                '--color[List color name; with --private also accepts #RRGGBB]:color:' \
                '--private[Use private ReminderKit for list appearance and grocery metadata]' \
                '--symbol[Official Reminders list symbol]:symbol:' \
                '--emoji[Private Reminders list emoji badge]:emoji:' \
                '--groceries[Create as a Reminders Groceries list]' \
                '--grocery-locale[Groceries locale identifier]:locale:' \
                '--json[JSON output]'
            return
            ;;
        list-edit)
            _arguments \
                '--list-id[Edit a list by stable numeric ID]:id:' \
                '--new-name[Rename the list through private ReminderKit]:name:' \
                '--color[List color name or #RRGGBB]:color:' \
                '--private[Required for list appearance and grocery metadata writes]' \
                '--symbol[Official Reminders list symbol]:symbol:' \
                '--emoji[Private Reminders list emoji badge]:emoji:' \
                '--groceries[Convert to a Reminders Groceries list]' \
                '--standard[Convert a Groceries list back to a standard list]' \
                '--grocery-locale[Groceries locale identifier]:locale:' \
                '--json[JSON output]'
            return
            ;;
        list-rename)
            _arguments \
                '--list-id[Rename list by stable numeric ID]:id:' \
                '--new-name[New list name, useful with --list-id]:name:' \
                '--json[JSON output]'
            return
            ;;
        list-pin|list-unpin)
            _arguments \
                '--private[Use private ReminderKit list pinning]' \
                '--list-id[Target list by stable numeric ID]:id:' \
                '--smart-list-id[Target smart list by stable numeric ID]:id:' \
                '--json[JSON output]'
            return
            ;;
        list-delete)
            _arguments \
                '--list-id[Delete list by stable numeric ID]:id:' \
                '--force[Skip confirmation prompt]' \
                '--json[JSON output]'
            return
            ;;
    esac
    _describe 'command' commands
}
compdef _remctl remctl

"""#

    public static let bash: String = #"""
_remctl() {
    local cur prev commands
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    commands="lists smart-lists templates template-info show add done undone edit delete search today upcoming overdue flagged urgent flag unflag tags subtasks info sections sharees stats link open export import list-symbols list-create smart-list-create smart-list-edit smart-list-delete template-create template-apply template-delete list-edit list-pin list-unpin list-rename list-delete onboard doctor setup permissions completion"

    local cmd="${COMP_WORDS[1]}"
    if [ "$cmd" = "add" ]; then
        COMPREPLY=( $(compgen -W "--private --grocery --section --section-id --new-section --subtask --image --assign --unassign --urgent --no-urgent --early-reminder --url --tags -t --list -l --list-id --notes -n --due -d --priority -p --flag -f --recurrence --alarm --json" -- "$cur") )
        return
    elif [ "$cmd" = "edit" ]; then
        COMPREPLY=( $(compgen -W "--private --grocery --section --section-id --new-section --subtask --image --assign --unassign --flagged --no-flagged --urgent --no-urgent --early-reminder --location-title --latitude --longitude --radius --proximity --title --list -l --list-id --url --tags -t --notes -n --due -d --priority -p --recurrence --alarm --json" -- "$cur") )
        return
    elif [ "$cmd" = "done" ]; then
        COMPREPLY=( $(compgen -W "--date --json" -- "$cur") )
        return
    elif [ "$cmd" = "sharees" ]; then
        COMPREPLY=( $(compgen -W "--list-id --json" -- "$cur") )
        return
    elif [ "$cmd" = "doctor" ]; then
        COMPREPLY=( $(compgen -W "--for-agent --json" -- "$cur") )
        return
    elif [ "$cmd" = "show" ]; then
        COMPREPLY=( $(compgen -W "--list-id --completed --via-eventkit --verbose -v --json" -- "$cur") )
        return
    elif [ "$cmd" = "search" ]; then
        COMPREPLY=( $(compgen -W "--completed --via-eventkit --verbose -v --json" -- "$cur") )
        return
    elif [ "$cmd" = "today" ]; then
        COMPREPLY=( $(compgen -W "--no-overdue --via-eventkit --verbose -v --json" -- "$cur") )
        return
    elif [ "$cmd" = "upcoming" ]; then
        COMPREPLY=( $(compgen -W "--via-eventkit --verbose -v --json" -- "$cur") )
        return
    elif [ "$cmd" = "link" ]; then
        COMPREPLY=( $(compgen -W "--list -l --list-id --completed --json" -- "$cur") )
        return
    elif [ "$cmd" = "export" ]; then
        COMPREPLY=( $(compgen -W "--list -l --list-id --format --json" -- "$cur") )
        return
    elif [ "$cmd" = "list-symbols" ]; then
        COMPREPLY=( $(compgen -W "--html --preview --json" -- "$cur") )
        return
    elif [ "$cmd" = "list-create" ]; then
        COMPREPLY=( $(compgen -W "--color --private --symbol --emoji --groceries --grocery-locale --json" -- "$cur") )
        return
    elif [ "$cmd" = "smart-list-create" ]; then
        COMPREPLY=( $(compgen -W "--private --color --symbol --emoji --match --filter-json --flagged --priority --tags --tag-match --any-tag --date --date-today-include-past-due --date-on --date-before --date-after --date-range --time --include-list --include-list-id --vehicle --location-title --latitude --longitude --radius --proximity --json" -- "$cur") )
        return
    elif [ "$cmd" = "smart-list-edit" ]; then
        COMPREPLY=( $(compgen -W "--private --smart-list-id --color --symbol --emoji --match --filter-json --flagged --priority --tags --tag-match --any-tag --date --date-today-include-past-due --date-on --date-before --date-after --date-range --time --include-list --include-list-id --vehicle --location-title --latitude --longitude --radius --proximity --json" -- "$cur") )
        return
    elif [ "$cmd" = "smart-list-delete" ]; then
        COMPREPLY=( $(compgen -W "--private --smart-list-id --force --json" -- "$cur") )
        return
    elif [ "$cmd" = "templates" ]; then
        COMPREPLY=( $(compgen -W "--json" -- "$cur") )
        return
    elif [ "$cmd" = "template-info" ]; then
        COMPREPLY=( $(compgen -W "--template-id --json" -- "$cur") )
        return
    elif [ "$cmd" = "template-create" ]; then
        COMPREPLY=( $(compgen -W "--from-list --from-list-id --include-completed --private --json" -- "$cur") )
        return
    elif [ "$cmd" = "template-apply" ]; then
        COMPREPLY=( $(compgen -W "--template-id --private --json" -- "$cur") )
        return
    elif [ "$cmd" = "template-delete" ]; then
        COMPREPLY=( $(compgen -W "--template-id --private --force --json" -- "$cur") )
        return
    elif [ "$cmd" = "list-edit" ]; then
        COMPREPLY=( $(compgen -W "--list-id --new-name --color --private --symbol --emoji --groceries --standard --grocery-locale --json" -- "$cur") )
        return
    elif [ "$cmd" = "list-pin" ] || [ "$cmd" = "list-unpin" ]; then
        COMPREPLY=( $(compgen -W "--private --list-id --smart-list-id --json" -- "$cur") )
        return
    elif [ "$cmd" = "list-rename" ]; then
        COMPREPLY=( $(compgen -W "--list-id --new-name --json" -- "$cur") )
        return
    elif [ "$cmd" = "list-delete" ]; then
        COMPREPLY=( $(compgen -W "--list-id --force --json" -- "$cur") )
        return
    elif [ $COMP_CWORD -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    fi
}
complete -F _remctl remctl

"""#

    public static let fish: String = #"""
# Fish completion for remctl
complete -c remctl -n "__fish_use_subcommand" -a lists -d "List all iCloud reminder lists"
complete -c remctl -n "__fish_use_subcommand" -a smart-lists -d "Inspect Reminders smart lists"
complete -c remctl -n "__fish_use_subcommand" -a templates -d "Inspect saved Reminders templates"
complete -c remctl -n "__fish_use_subcommand" -a template-info -d "Show a saved Reminders template"
complete -c remctl -n "__fish_use_subcommand" -a show -d "Show reminders in a list"
complete -c remctl -n "__fish_use_subcommand" -a add -d "Add a reminder"
complete -c remctl -n "__fish_use_subcommand" -a done -d "Complete a reminder"
complete -c remctl -n "__fish_use_subcommand" -a undone -d "Uncomplete a reminder"
complete -c remctl -n "__fish_use_subcommand" -a edit -d "Edit a reminder"
complete -c remctl -n "__fish_use_subcommand" -a delete -d "Delete a reminder"
complete -c remctl -n "__fish_use_subcommand" -a search -d "Search reminders"
complete -c remctl -n "__fish_use_subcommand" -a today -d "Due today + overdue"
complete -c remctl -n "__fish_use_subcommand" -a upcoming -d "Next N days"
complete -c remctl -n "__fish_use_subcommand" -a overdue -d "All overdue reminders"
complete -c remctl -n "__fish_use_subcommand" -a flagged -d "Flagged reminders"
complete -c remctl -n "__fish_use_subcommand" -a urgent -d "Urgent reminders"
complete -c remctl -n "__fish_use_subcommand" -a flag -d "Flag a reminder"
complete -c remctl -n "__fish_use_subcommand" -a unflag -d "Unflag a reminder"
complete -c remctl -n "__fish_use_subcommand" -a tags -d "List all tags"
complete -c remctl -n "__fish_use_subcommand" -a subtasks -d "Show subtasks"
complete -c remctl -n "__fish_use_subcommand" -a info -d "Full detail view"
complete -c remctl -n "__fish_use_subcommand" -a sections -d "Show sections"
complete -c remctl -n "__fish_use_subcommand" -a sharees -d "Show people available for assignment in a shared list"
complete -c remctl -n "__fish_use_subcommand" -a stats -d "Statistics"
complete -c remctl -n "__fish_use_subcommand" -a link -d "Get deep links"
complete -c remctl -n "__fish_use_subcommand" -a open -d "Open in Reminders.app"
complete -c remctl -n "__fish_use_subcommand" -a export -d "Export reminders"
complete -c remctl -n "__fish_use_subcommand" -a import -d "Import reminders"
complete -c remctl -n "__fish_use_subcommand" -a list-symbols -d "List official Reminders list symbols"
complete -c remctl -n "__fish_use_subcommand" -a list-create -d "Create a new list"
complete -c remctl -n "__fish_use_subcommand" -a smart-list-create -d "Create a private custom smart list"
complete -c remctl -n "__fish_use_subcommand" -a smart-list-edit -d "Edit a private custom smart list"
complete -c remctl -n "__fish_use_subcommand" -a smart-list-delete -d "Delete a private custom smart list"
complete -c remctl -n "__fish_use_subcommand" -a template-create -d "Create a private Reminders template from an entire list"
complete -c remctl -n "__fish_use_subcommand" -a template-apply -d "Create a list from a saved Reminders template"
complete -c remctl -n "__fish_use_subcommand" -a template-delete -d "Delete a saved Reminders template"
complete -c remctl -n "__fish_use_subcommand" -a list-edit -d "Edit private list appearance"
complete -c remctl -n "__fish_use_subcommand" -a list-pin -d "Pin a list or smart list in Reminders"
complete -c remctl -n "__fish_use_subcommand" -a list-unpin -d "Unpin a list or smart list in Reminders"
complete -c remctl -n "__fish_use_subcommand" -a list-rename -d "Rename a list"
complete -c remctl -n "__fish_use_subcommand" -a list-delete -d "Delete a list"
complete -c remctl -n "__fish_use_subcommand" -a onboard -d "Prompt for macOS permissions and verify readiness"
complete -c remctl -n "__fish_use_subcommand" -a doctor -d "Diagnose setup and runtime issues"
complete -c remctl -n "__fish_use_subcommand" -a setup -d "Install shell completions"
complete -c remctl -n "__fish_use_subcommand" -a permissions -d "Open guided macOS permission helper"
complete -c remctl -n "__fish_use_subcommand" -a completion -d "Generate shell completions"
complete -c remctl -n "__fish_seen_subcommand_from doctor" -l for-agent -d "Print agent-focused context and TCC guidance"
complete -c remctl -n "__fish_seen_subcommand_from show" -l list-id -d "Show list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from show" -l completed -d "Include completed reminders"
complete -c remctl -n "__fish_seen_subcommand_from show" -l via-eventkit -d "Limited read-only EventKit fallback; no numeric ids or private metadata"
complete -c remctl -n "__fish_seen_subcommand_from search" -l via-eventkit -d "Limited read-only EventKit fallback; no numeric ids or private metadata"
complete -c remctl -n "__fish_seen_subcommand_from today" -l via-eventkit -d "Limited read-only EventKit fallback; no numeric ids or private metadata"
complete -c remctl -n "__fish_seen_subcommand_from upcoming" -l via-eventkit -d "Limited read-only EventKit fallback; no numeric ids or private metadata"
complete -c remctl -n "__fish_seen_subcommand_from show" -s v -l verbose -d "Verbose output"
complete -c remctl -n "__fish_seen_subcommand_from link" -s l -l list -d "Get links for active reminders in list" -r
complete -c remctl -n "__fish_seen_subcommand_from link" -l list-id -d "Get links for active reminders in list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from link" -l completed -d "Include completed reminders"
complete -c remctl -n "__fish_seen_subcommand_from export" -s l -l list -d "Export only this list" -r
complete -c remctl -n "__fish_seen_subcommand_from export" -l list-id -d "Export only this list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from export" -l format -d "Export format" -a "json csv"
complete -c remctl -n "__fish_seen_subcommand_from list-symbols" -l html -d "Write a standalone HTML preview contact sheet" -r
complete -c remctl -n "__fish_seen_subcommand_from list-symbols" -l preview -d "Generate and open the HTML preview contact sheet"
complete -c remctl -n "__fish_seen_subcommand_from list-create" -l color -d "List color name; with --private also accepts #RRGGBB" -r
complete -c remctl -n "__fish_seen_subcommand_from list-create" -l private -d "Use private ReminderKit list appearance writes"
complete -c remctl -n "__fish_seen_subcommand_from list-create" -l symbol -d "Official Reminders list symbol name" -r
complete -c remctl -n "__fish_seen_subcommand_from list-create" -l emoji -d "Private Reminders list emoji badge" -r
complete -c remctl -n "__fish_seen_subcommand_from list-create" -l groceries -d "Create as a Reminders Groceries list"
complete -c remctl -n "__fish_seen_subcommand_from list-create" -l grocery-locale -d "Groceries locale identifier" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create" -l private -d "Use private ReminderKit smart-list creation"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l color -d "Smart-list color name or #RRGGBB" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l symbol -d "Official Reminders list symbol" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l emoji -d "Private Reminders emoji badge" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create" -l flagged -d "Filter to flagged reminders"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create" -l priority -d "Priority filter" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l match -d "Match all or any filters" -a "all any"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l filter-json -d "Raw official filter JSON or @path" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l tags -d "Selected tag filter, comma-separated" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l tag-match -d "Selected tag matching mode" -a "all any"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l any-tag -d "Filter to reminders with any tag"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l date -d "Date filter" -a "any today"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l date-today-include-past-due -d "Include past due with today"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l date-on -d "On date" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l date-before -d "Before date" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l date-after -d "After date" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l date-range -d "Date range START,END" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l time -d "Time filter" -a "morning afternoon evening night"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l include-list -d "Include one list" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l include-list-id -d "Include numeric list ID" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l vehicle -d "Vehicle filter" -a "connected"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l location-title -d "Location title" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l latitude -d "Latitude" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l longitude -d "Longitude" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l radius -d "Radius meters" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-create smart-list-edit" -l proximity -d "Location proximity" -a "enter leave arriving leaving"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-edit" -l private -d "Use private ReminderKit smart-list editing"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-edit" -l smart-list-id -d "Edit by numeric smart-list ID" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-edit" -l flagged -d "Filter to flagged reminders"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-edit" -l priority -d "Priority filter" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-edit" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-delete" -l private -d "Use private ReminderKit smart-list deletion"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-delete" -l smart-list-id -d "Delete by numeric smart-list ID" -r
complete -c remctl -n "__fish_seen_subcommand_from smart-list-delete" -l force -d "Skip confirmation prompt"
complete -c remctl -n "__fish_seen_subcommand_from smart-list-delete" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from templates" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from template-info" -l template-id -d "Read by numeric template ID" -r
complete -c remctl -n "__fish_seen_subcommand_from template-info" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from template-create" -l from-list -d "Source list name" -r
complete -c remctl -n "__fish_seen_subcommand_from template-create" -l from-list-id -d "Source list numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from template-create" -l include-completed -d "Include completed reminders"
complete -c remctl -n "__fish_seen_subcommand_from template-create" -l private -d "Use private ReminderKit template creation"
complete -c remctl -n "__fish_seen_subcommand_from template-create" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from template-apply" -l template-id -d "Apply by numeric template ID" -r
complete -c remctl -n "__fish_seen_subcommand_from template-apply" -l private -d "Use private ReminderKit template application"
complete -c remctl -n "__fish_seen_subcommand_from template-apply" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from template-delete" -l template-id -d "Delete by numeric template ID" -r
complete -c remctl -n "__fish_seen_subcommand_from template-delete" -l private -d "Use private ReminderKit template deletion"
complete -c remctl -n "__fish_seen_subcommand_from template-delete" -l force -d "Skip confirmation prompt"
complete -c remctl -n "__fish_seen_subcommand_from template-delete" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l list-id -d "Edit a list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l new-name -d "Rename the list through private ReminderKit" -r
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l color -d "List color name or #RRGGBB" -r
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l private -d "Required for list appearance writes"
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l symbol -d "Official Reminders list symbol name" -r
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l emoji -d "Private Reminders list emoji badge" -r
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l groceries -d "Convert to a Reminders Groceries list"
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l standard -d "Convert a Groceries list back to a standard list"
complete -c remctl -n "__fish_seen_subcommand_from list-edit" -l grocery-locale -d "Groceries locale identifier" -r
complete -c remctl -n "__fish_seen_subcommand_from list-pin list-unpin" -l private -d "Use private ReminderKit list pinning"
complete -c remctl -n "__fish_seen_subcommand_from list-pin list-unpin" -l list-id -d "Target list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from list-pin list-unpin" -l smart-list-id -d "Target smart list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from list-pin list-unpin" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from list-rename" -l list-id -d "Rename list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from list-rename" -l new-name -d "New list name" -r
complete -c remctl -n "__fish_seen_subcommand_from list-delete" -l list-id -d "Delete list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from list-delete" -l force -d "Skip confirmation prompt"
complete -c remctl -n "__fish_seen_subcommand_from add" -l private -d "Use unsupported private ReminderKit metadata writes"
complete -c remctl -n "__fish_seen_subcommand_from add" -l section -d "Assign to existing section" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l section-id -d "Assign to section by stable ID" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l new-section -d "Create and assign to new section" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l subtask -d "Add private subtask title or JSON object" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l image -d "Add private image attachment" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l assign -d "Assign to shared-list user" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l unassign -d "Clear existing assignment"
complete -c remctl -n "__fish_seen_subcommand_from add" -l grocery -d "Auto-categorize in a Groceries list"
complete -c remctl -n "__fish_seen_subcommand_from add" -l urgent -d "Set private urgent state"
complete -c remctl -n "__fish_seen_subcommand_from add" -l no-urgent -d "Clear private urgent state"
complete -c remctl -n "__fish_seen_subcommand_from add" -l early-reminder -d "Set Early Reminder delta, e.g. 15m, 1h, clear" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l url -d "URL, web rich link with --private" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -s t -l tags -d "Tags, synced with --private" -r
complete -c remctl -n "__fish_seen_subcommand_from add" -l list-id -d "Target list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from done" -l date -d "Set completion date" -r
complete -c remctl -n "__fish_seen_subcommand_from done" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from sharees" -l list-id -d "Shared list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from sharees" -l json -d "JSON output"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l private -d "Use unsupported private ReminderKit metadata writes"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l section -d "Assign to existing section" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l section-id -d "Assign to section by stable ID" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l new-section -d "Create and assign to new section" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l subtask -d "Add private subtask title or JSON object" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l image -d "Add private image attachment" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l assign -d "Assign to shared-list user" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l unassign -d "Clear existing assignment"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l grocery -d "Auto-categorize in the reminder Groceries list"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l flagged -d "Set real private flag"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l no-flagged -d "Clear real private flag"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l urgent -d "Set private urgent state"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l no-urgent -d "Clear private urgent state"
complete -c remctl -n "__fish_seen_subcommand_from edit" -l early-reminder -d "Set Early Reminder delta, e.g. 15m, 1h, clear" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l location-title -d "Location alarm title" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l latitude -d "Location alarm latitude" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l longitude -d "Location alarm longitude" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l radius -d "Location alarm radius" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l proximity -d "Location trigger" -a "arriving leaving"
complete -c remctl -n "__fish_seen_subcommand_from edit" -s l -l list -d "Move to list" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -l list-id -d "Move to list by stable numeric ID" -r
complete -c remctl -n "__fish_seen_subcommand_from edit" -s t -l tags -d "Synced tags with --private" -r

"""#
}

// ── Shell detection helpers ──────────────────────────────────────────────────

/// Returns the basename of `$SHELL`, or `"zsh"` if unset/empty.
/// Port of `detect_shell_name()` (remctl:6961).
/// Port of `zsh_completion_hint` (upstream aba7cf5): the ~/.zshrc lines that make the
/// installed completion loadable.
public func zshCompletionHint(_ completionPath: URL) -> String {
    let directory = completionPath.deletingLastPathComponent().path
    return "Add to ~/.zshrc:\n    fpath=(\(directory) $fpath)\n    autoload -Uz compinit && compinit"
}

/// Port of `zsh_completion_loadable` (upstream aba7cf5): true when the completion
/// directory is on the exported FPATH, or mentioned (absolute, ~/rel, or $HOME/rel)
/// in the usual zsh startup files (honoring ZDOTDIR). False otherwise — doctor then
/// warns with `zshCompletionHint`.
public func zshCompletionLoadable(
    _ completionPath: URL,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    let dir = completionPath.deletingLastPathComponent()
    let target = dir.standardizedFileURL.resolvingSymlinksInPath().path

    if let exported = env["FPATH"], !exported.isEmpty {
        for entry in exported.split(separator: ":").map(String.init) where !entry.isEmpty {
            let resolved = URL(fileURLWithPath: (entry as NSString).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath().path
            if resolved == target { return true }
        }
    }

    let home = env["HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    let zdotdir = env["ZDOTDIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? home
    let configFiles = [".zshrc", ".zprofile", ".zshenv"].map { zdotdir.appendingPathComponent($0) }

    var needles = Set([dir.path, target])
    let homePath = home.standardizedFileURL.resolvingSymlinksInPath().path
    if target.hasPrefix(homePath + "/") {
        let rel = String(target.dropFirst(homePath.count + 1))
        needles.insert("~/" + rel)
        needles.insert("$HOME/" + rel)
    }
    for configFile in configFiles {
        guard let text = try? String(contentsOf: configFile, encoding: .utf8) else { continue }
        if needles.contains(where: { !$0.isEmpty && text.contains($0) }) { return true }
    }
    return false
}

public func detectShellName(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let shell = env["SHELL"] ?? ""
    guard !shell.isEmpty else { return "zsh" }
    return URL(fileURLWithPath: shell).lastPathComponent
}

/// Returns the per-shell completion install path, expanding `~` to HOME.
/// Port of `completion_target_path(shell)` (remctl:6966).
/// Fish uses the LITERAL path `~/.config` (not $XDG_CONFIG_HOME).
public func completionTargetPath(
    _ shell: String,
    env: [String: String] = ProcessInfo.processInfo.environment
) throws -> URL {
    let home = env["HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser
    switch shell {
    case "zsh":
        return home.appendingPathComponent(".zsh/completions/_remctl")
    case "bash":
        return home.appendingPathComponent(".local/share/bash-completion/completions/remctl")
    case "fish":
        return home.appendingPathComponent(".config/fish/completions/remctl.fish")
    default:
        throw CLIError("Unsupported shell '\(shell)'")
    }
}

/// If `requested != "auto"`, returns it verbatim (including `"skip"`).
/// If `"auto"`, detects the shell name and returns it iff it is zsh/bash/fish; else `"skip"`.
/// Port of `resolve_setup_shell(requested_shell)` (remctl:6983).
public func resolveSetupShell(
    _ requested: String,
    env: [String: String] = ProcessInfo.processInfo.environment
) -> String {
    guard requested == "auto" else { return requested }
    let detected = detectShellName(env: env)
    return ["zsh", "bash", "fish"].contains(detected) ? detected : "skip"
}

/// Returns the completion script for `shell` (zsh/bash/fish), or throws a `CLIError`.
/// Port of `get_completion_script(shell)` (remctl:6951).
public func completionScript(for shell: String) throws -> String {
    switch shell {
    case "zsh":  return CompletionScripts.zsh
    case "bash": return CompletionScripts.bash
    case "fish": return CompletionScripts.fish
    default: throw CLIError("Unsupported shell '\(shell)'. Use bash, zsh, or fish.")
    }
}
