#!/usr/bin/env bash

# =============================================================================
# Переменные
# =============================================================================

BASE_DIR="$(realpath "$(dirname "$0")")"

# Подключаем общие библиотеки
source "$BASE_DIR/lib/constants.sh"
source "$BASE_DIR/lib/common.sh"
source "$BASE_DIR/lib/consts.sh"

detect_init_system() {
    COMM=$(sudo cat /proc/1/comm 2>/dev/null | tr -d '\n')
    EXE=$(sudo readlink -f /proc/1/exe 2>/dev/null)
    EXE_NAME=$(basename "$EXE" 2>/dev/null)

    # SYSTEMD
    if [ "$EXE_NAME" = "systemd" ] || [ -d "/run/systemd/system" ]; then
        echo "systemd"
        return
    fi

    # DINIT
    if [ "$EXE_NAME" = "dinit" ] || [ "$COMM" = "dinit" ]; then
        echo "dinit"
        return
    fi

    # RUNIT
    case "$EXE_NAME" in
    runit*)
        echo "runit"
        return
        ;;
    esac

    # S6
    case "$EXE_NAME" in
    s6-svscan*)
        echo "s6"
        return
        ;;
    esac
    if [ -d "/run/s6" ] || [ -d "/var/run/s6" ]; then
        echo "s6"
        return
    fi

    # OPENRC
    if [ -d "/run/openrc" ] || [ -f "/sbin/rc" ] || [ -f "/etc/init.d/rc" ] || type rc-status >/dev/null 2>&1; then
        echo "openrc"
        return
    fi

    #SYSVINIT
    if [ "$EXE_NAME" = "init" ] || [ "$COMM" = "init" ]; then
        echo "sysvinit"
        return
    fi

    echo "unknown/container ($EXE_NAME)"
    exit 1
}

INIT_SYS=$(detect_init_system)
INIT_SCRIPT="$BACKENDS_DIR/${INIT_SYS}.sh"

if [[ -f "$INIT_SCRIPT" ]]; then
    echo "Обнаружена система: $INIT_SYS. Подключаем $INIT_SCRIPT"
    source "$INIT_SCRIPT"
else
    echo "Ошибка: Не найден скрипт для системы $INIT_SYS ($INIT_SCRIPT)"
    exit 1
fi

# Основное меню управления
show_menu() {
    check_service_status
    local status=$?

    case $status in
    1)
        echo "1. Установить и запустить сервис"
        echo "2. Изменить конфигурацию"
        echo "3. Изменить версию Zapret"
        read -p "Выберите действие: " choice
        case $choice in
        1) install_service ;;
        2) create_conf_file ;;
        3) version_change ;;
        esac
        ;;
    2)
        echo "1. Удалить сервис"
        echo "2. Остановить сервис"
        echo "3. Перезапустить сервис"
        echo "4. Изменить конфигурацию"
        echo "5. Изменить версию Zapret"
        read -p "Выберите действие: " choice
        case $choice in
        1) remove_service ;;
        2) stop_service ;;
        3) restart_service ;;
        4) create_conf_file ;;
        5) version_change ;;
        esac
        ;;
    3)
        echo "1. Удалить сервис"
        echo "2. Запустить сервис"
        echo "3. Изменить конфигурацию"
        echo "4. Изменить версию Zapret"
        read -p "Выберите действие: " choice
        case $choice in
        1) remove_service ;;
        2) start_service ;;
        3) create_conf_file ;;
        4) version_change ;;
        esac
        ;;
    *)
        echo "Неправильный выбор."
        ;;
    esac
}

# Запуск интерактивного меню
run_interactive() {
    show_menu
    echo ""
    read -p "Нажмите Enter для выхода..."
}

# Функция для вывода текущей конфигурации
show_config() {
    if [ -f "$CONF_FILE" ]; then
        echo "Текущая конфигурация:"
        echo
        cat "$CONF_FILE"
        echo
    else
        echo "Файл конфигурации отсутствует"
    fi
}

# Функция для обновления конфигурации с рестартом сервиса.
update_config() {
    local strategy="$1"
    local interface="${2:-any}"
    local gamefilter="$3"

    # Валидация и нормализация названия стратегии (функция из lib/common.sh)
    local normalized_strategy
    if ! normalized_strategy=$(normalize_strategy "$strategy"); then
        echo "Несуществующая стратегия!"
        show_strategies
        exit 1
    fi

    if [[ "$interface" != "any" ]]; then
        interface_match=$(ls /sys/class/net | grep -E "^${interface}$")
        if [ ! -n "$interface_match" ]; then
            echo "Несуществующий интерфейс!"
            local interfaces=("any" $(ls /sys/class/net))
            echo "Доступные интерфейсы: ${interfaces[@]}"
            exit 1
        fi
    fi

    cat > "$CONF_FILE" << ENV
interface=${interface}
gamefilter=${gamefilter}
strategy=${normalized_strategy}
ENV

    echo "Конфигурация обновлена."
    show_config

    if [ "$RESTART_SERVICE" = true ]; then
        restart_service
    fi
}

# Функция для смены версии zapret
version_change() {
    # Заходим
    cd "$REPO_DIR"
    echo "**ВНИМАНИЕ! ФУНКЦИЯ ТЕСТОВАЯ! КРАЙНЕ РАННИЕ ИЛИ СЛИШКОМ НОВЫЕ ВЕРСИИ РАБОТАТЬ НЕ ОБЯЗАНЫ!**"
    echo "**ПРИ ПРОБЛЕМАХ С ДАННЫМИ ВЕРСИЯМИ ISSUE ОТКРЫВАТЬ НЕ СЛЕДУЕТ!**"
    echo "Выберите версию zapret"
    select version in "$MAIN_REPO_REV (default)" $(git tag); do
        if [[ -n "$version" ]]; then
            log "Выбрана версия $version"
            if [[ "$MAIN_REPO_REV (default)" == "$version" ]]; then
                git checkout -f $MAIN_REPO_REV
            else
                git checkout -f $version
            fi
            # Выходим
            cd "$BASE_DIR"
            # Переименовываем
            "$BASE_DIR/rename_bat.sh" || handle_error "Ошибка при переименовании файлов"
            echo "$BASE_DIR/rename_bat.sh"
            # Переделываем конфигурацию
            create_conf_file
            # Убираемся
            exit 0
        fi
        echo "Такой версии нет"
    done
}

# Помощь
show_usage() {
    echo "Usage:"
    echo "    $(basename "$0")         Run interactive service manager"
    echo
    echo "Commands:"
    echo "       --status        Show service status"
    echo "    -i --install       Install and start service"
    echo "    -R --remove        Remove service"
    echo "    -s --start         Start service"
    echo "    -S --stop          Stop service"
    echo "    -r --restart       Just restart the service"
    echo "    -d --download      Download strategies repository"
    echo "    -V --switchver     Switch zapret version"
    echo "    -l --strategies    List available strategies"
    echo "    -c --config        Show current config"
    echo "    -h --help          Show this help"
    echo
    echo "Update configuration:"
    echo "    $(basename "$0") [options] <STRATEGY> [INTERFACE]"
    echo
    echo "Options:"
    echo "    -g --gamefilter      Enable gamefilter"
    echo "    -n --norestart       Do not restart the service"
}

# Парсинг флагов
GAMEFILTER=false
RESTART_SERVICE=true

while [[ $# -gt 0 ]]; do
    case $1 in
        --status) check_service_status
            exit 0
            ;;
        -i|--install)
            install_service
            exit 0
            ;;
        -R|--remove)
            remove_service
            exit 0
            ;;
        -s|--start)
            start_service
            exit 0
            ;;
        -S|--stop)
            stop_service
            exit 0
            ;;
        -r|--restart)
            restart_service
            exit 0
            ;;
        -l|--strategies)
            show_strategies
            exit 0
            ;;
        -V|--switchver)
            version_change
            ;;
        -d|--download)
            check_dependencies
            setup_repository
            echo "Стратегии загружены."
            exit 0
            ;;
        -c|--config)
            show_config
            exit 0
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -g|--gamefilter)
            GAMEFILTER=true
            shift
            ;;
        -n|--norestart)
            RESTART_SERVICE=false
            shift
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

# Парсинг аргументов
case $# in
    0)
        # Run original interactive service manager
        run_interactive
        ;;
    1)
        update_config "$1" "any" "$GAMEFILTER"
        ;;
    2)
        update_config "$1" "$2" "$GAMEFILTER"
        ;;
    *)
        echo "Wrong arguments!"
        echo "Run '$(basename "$0") -h' for help"
        exit 1
        ;;
esac
