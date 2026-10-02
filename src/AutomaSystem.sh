#!/usr/bin/env bash
#
# AutomaSystem — manutenção diária para Linux
#
# Detecta a distro via /etc/os-release, escolhe o gerenciador de pacotes
# (apt, dnf, pacman, zypper ou portage) e executa as tarefas de manutenção correspondentes.

set -uo pipefail

INSTALL_PATH="/usr/local/bin/AutomaSystem"
DRY_RUN=0
FULL=0

# ---------------------------------------------------------------------------
# Utilitários do script
# ---------------------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_root() {
    [ "$(id -u)" -eq 0 ]
}

# Executa um comando como root (usa sudo quando necessário)
priv() {
    if is_root; then "$@"; else sudo "$@"; fi
}

usage() {
    cat <<'EOF'
Uso:
    AutomaSystem               executa a manutenção padrão
    AutomaSystem --dry-run     mostra o que seria executado, sem rodar nada
    AutomaSystem --full        inclui tarefas marcadas como "risky"
    AutomaSystem --install     instala o comando em /usr/local/bin
    AutomaSystem --uninstall   remove o comando de /usr/local/bin
    AutomaSystem --help        mostra esta ajuda
EOF
}

# ---------------------------------------------------------------------------
# Lista de tarefas (arrays paralelos)
# ---------------------------------------------------------------------------

TASK_DESC=()    # descrição
TASK_CMD=()     # comando (executado com sh -c)
TASK_REQ=()     # binário necessário no PATH (vazio = nenhum)
TASK_RISKY=()   # 1 = só roda com --full

# add_task "descrição" "comando" ["binário requerido"] [risky: 0|1]
add_task() {
    TASK_DESC+=("$1")
    TASK_CMD+=("$2")
    TASK_REQ+=("${3:-}")
    TASK_RISKY+=("${4:-0}")
}

# ---------------------------------------------------------------------------
# Comandos de manutenção por gerenciador de pacotes
# ---------------------------------------------------------------------------

load_tasks_apt() { # Distros de base Debian/Ubuntu #
    add_task "Atualizar índice de pacotes"       "apt-get update"
    add_task "Atualizar pacotes instalados"      "apt-get upgrade -y"
    add_task "Remover dependências órfãs"        "apt-get autoremove -y"
    add_task "Limpar cache de pacotes obsoletos" "apt-get autoclean"
}

load_tasks_dnf() { # Distros de base Fedora/Red Hat #
    add_task "Atualizar pacotes (refresh dos metadados)" "dnf upgrade --refresh -y"
    add_task "Remover dependências órfãs"                "dnf autoremove -y"
    add_task "Limpar cache de pacotes"                   "dnf clean packages"
}

load_tasks_pacman() { # Distros de base Arch #
    add_task "Sincronizar e atualizar o sistema" "pacman -Syu --noconfirm"
    add_task "Remover pacotes órfãos" \
        'orphans=$(pacman -Qtdq); if [ -n "$orphans" ]; then pacman -Rns --noconfirm $orphans; else echo "Nenhum órfão."; fi'
    # paccache vem do pacote pacman-contrib
    add_task "Limpar cache antigo (mantém 3 versões)" "paccache -r" "paccache"
}

load_tasks_zypper() { # Distros de base suse # 
    add_task "Atualizar repositórios"        "zypper --non-interactive refresh"
    add_task "Atualizar pacotes instalados"  "zypper --non-interactive update"
    add_task "Limpar cache dos repositórios" "zypper --non-interactive clean"
}

load_tasks_portage() { # Distros dde base Gentoo #
    add_task "Sincronizar árvore do Portage"   "emerge --sync"
    add_task "Atualizar @world (deep, newuse)" "emerge --update --deep --newuse --with-bdeps=y @world"
    add_task "Reconstruir pacotes preservados" "emerge @preserved-rebuild"
    # eclean-dist vem do pacote app-portage/gentoolkit
    # se não tiver instalado não funciona
    add_task "Limpar distfiles antigos"        "eclean-dist --deep" "eclean-dist"
    add_task "Remover pacotes sem dependentes (depclean)" "emerge --depclean" "" 1
}

# Tarefas comuns a qualquer distro independente do package manager, rodadas depois das específicas
load_tasks_common() {
    add_task "Limpar logs do journal com mais de 7 dias" "journalctl --vacuum-time=7d" "journalctl"
    add_task "Verificar serviços systemd com falha"      "systemctl --failed --no-pager" "systemctl"
    add_task "Mostrar uso de disco"                      "df -h -x tmpfs -x devtmpfs"
}

# ---------------------------------------------------------------------------
# Detecção da distro / gerenciador de pacotes
# ---------------------------------------------------------------------------

detect_package_manager() {
    local os_file=""
    for f in /etc/os-release /usr/lib/os-release; do
        if [ -r "$f" ]; then os_file="$f"; break; fi
    done
    if [ -z "$os_file" ]; then
        echo "Erro: não foi possível ler /etc/os-release. Este sistema é Linux?" >&2
        return 1
    fi

    # Lê em subshell para não poluir as variáveis do script
    local info
    info=$(
        # shellcheck disable=SC1090
        . "$os_file"
        printf '%s\n%s\n%s\n' "${ID:-}" "${ID_LIKE:-}" "${PRETTY_NAME:-${NAME:-Linux}}"
    )
    DISTRO_ID=$(sed -n '1p' <<<"$info" | tr '[:upper:]' '[:lower:]')
    DISTRO_LIKE=$(sed -n '2p' <<<"$info" | tr '[:upper:]' '[:lower:]')
    DISTRO_NAME=$(sed -n '3p' <<<"$info")

    # 1) Pelo ID da distro
    case "$DISTRO_ID" in
        debian|ubuntu|linuxmint|pop|raspbian|kali|elementary|zorin|neon) PM=apt;     return 0 ;;
        fedora|rhel|centos|rocky|almalinux|nobara)                       PM=dnf;     return 0 ;;
        arch|manjaro|endeavouros|garuda|cachyos|artix)                   PM=pacman;  return 0 ;;
        opensuse|opensuse-leap|opensuse-tumbleweed|sles|sled)            PM=zypper;  return 0 ;;
        gentoo|funtoo)                                                   PM=portage; return 0 ;;
    esac

    # 2) Pela "família" (ID_LIKE)
    local fam
    for fam in $DISTRO_LIKE; do
        case "$fam" in
            debian|ubuntu)       PM=apt;     return 0 ;;
            fedora|rhel|centos)  PM=dnf;     return 0 ;;
            arch)                PM=pacman;  return 0 ;;
            suse|opensuse)       PM=zypper;  return 0 ;;
            gentoo)              PM=portage; return 0 ;;
        esac
    done

    # 3) Último recurso: procurar o binário no PATH
    if   command_exists apt-get; then PM=apt
    elif command_exists dnf;     then PM=dnf
    elif command_exists pacman;  then PM=pacman
    elif command_exists zypper;  then PM=zypper
    elif command_exists emerge;  then PM=portage
    else
        echo "Erro: distro \"$DISTRO_ID\" não suportada (apt, dnf, pacman, zypper, portage)." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Instalação como comando "AutomaSystem"
# ---------------------------------------------------------------------------

install_command() {
    local src
    src=$(readlink -f "${BASH_SOURCE[0]}")

    if [ -e "$INSTALL_PATH" ] && [ "$src" = "$(readlink -f "$INSTALL_PATH")" ]; then
        echo "AutomaSystem já está instalado em $INSTALL_PATH."
        return 0
    fi
    if ! is_root && ! command_exists sudo; then
        echo "Erro: execute como root ou instale o sudo." >&2
        return 1
    fi
    if priv install -m 755 "$src" "$INSTALL_PATH"; then
        echo "Instalado em $INSTALL_PATH. Agora basta digitar: AutomaSystem"
    else
        echo "Falha ao instalar." >&2
        return 1
    fi
}

uninstall_command() {
    if ! is_root && ! command_exists sudo; then
        echo "Erro: execute como root ou instale o sudo." >&2
        return 1
    fi
    if priv rm -f "$INSTALL_PATH"; then
        echo "Removido $INSTALL_PATH."
    else
        echo "Falha ao remover." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Manutenção
# ---------------------------------------------------------------------------

run_maintenance() {
    detect_package_manager || exit 2

    echo "Sistema: $DISTRO_NAME"
    echo "Gerenciador de pacotes: $PM"
    [ "$DRY_RUN" -eq 1 ] && echo "Modo dry-run: nada será executado."

    if ! is_root && ! command_exists sudo && [ "$DRY_RUN" -eq 0 ]; then
        echo "Erro: execute como root ou instale o sudo." >&2
        exit 2
    fi

    "load_tasks_$PM"
    load_tasks_common

    local total=${#TASK_DESC[@]} failed=0 skipped=0
    local failed_list=() skipped_list=()
    local i desc cmd req risky shown

    for ((i = 0; i < total; i++)); do
        desc=${TASK_DESC[$i]}
        cmd=${TASK_CMD[$i]}
        req=${TASK_REQ[$i]}
        risky=${TASK_RISKY[$i]}

        if [ "$risky" -eq 1 ] && [ "$FULL" -eq 0 ]; then
            skipped_list+=("$desc (use --full)"); ((skipped++)); continue
        fi
        if [ -n "$req" ] && ! command_exists "$req"; then
            skipped_list+=("$desc (falta \"$req\")"); ((skipped++)); continue
        fi

        if is_root; then shown="$cmd"; else shown="sudo sh -c '$cmd'"; fi
        echo
        echo "▶ $desc"
        echo "  \$ $shown"

        [ "$DRY_RUN" -eq 1 ] && continue

        if ! priv sh -c "$cmd"; then
            failed_list+=("$desc"); ((failed++))
        fi
    done

    echo
    echo "──────── Resumo ────────"
    echo "Total: $total | Falhas: $failed | Ignoradas: $skipped"
    for desc in "${skipped_list[@]+"${skipped_list[@]}"}"; do echo "  ⏭ $desc"; done
    for desc in "${failed_list[@]+"${failed_list[@]}"}";   do echo "  ✖ $desc"; done

    [ "$failed" -gt 0 ] && return 1
    return 0
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

main() {
    local action="run" arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run)   DRY_RUN=1 ;;
            --full)      FULL=1 ;;
            --install)   action="install" ;;
            --uninstall) action="uninstall" ;;
            -h|--help)   usage; exit 0 ;;
            *) echo "Opção desconhecida: $arg" >&2; usage >&2; exit 2 ;;
        esac
    done

    case "$action" in
        install)   install_command;   exit $? ;;
        uninstall) uninstall_command; exit $? ;;
        run)       run_maintenance;   exit $? ;;
    esac
}

trap 'echo; echo "Interrompido." >&2; exit 130' INT

main "$@"