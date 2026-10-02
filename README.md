# AutomaSystem

Script de manutenção diária para Linux, escrito em bash. Ele identifica a distro em que está rodando, escolhe o gerenciador de pacotes correto e executa uma lista de tarefas de manutenção (atualização, limpeza de órfãos e de cache, verificação de serviços e disco).

Depois de instalado, basta digitar `AutomaSystem` no terminal.

## Recursos

- Detecção automática da distro via `/etc/os-release` (`ID`, depois `ID_LIKE`, depois binários no `PATH`)
- Suporte a cinco gerenciadores de pacotes: **apt**, **dnf**, **pacman**, **zypper** e **portage**
- Tarefas definidas em listas simples, fáceis de editar
- Modo `--dry-run` para ver o que seria executado sem rodar nada
- Tarefas arriscadas (como `emerge --depclean`) ficam desativadas por padrão e só rodam com `--full`
- Ferramentas opcionais ausentes são ignoradas em vez de causar erro
- Usa `sudo` automaticamente quando não está rodando como root
- Resumo no final com total, falhas e tarefas ignoradas
- Sem dependências além do bash e de utilitários básicos do sistema

## Distros suportadas

| Gerenciador | Distros reconhecidas diretamente | Famílias (`ID_LIKE`) |
|-------------|----------------------------------|----------------------|
| apt         | Debian, Ubuntu, Linux Mint, Pop!_OS, Raspbian, Kali, elementary, Zorin, KDE neon | `debian`, `ubuntu` |
| dnf         | Fedora, RHEL, CentOS, Rocky, AlmaLinux, Nobara | `fedora`, `rhel`, `centos` |
| pacman      | Arch, Manjaro, EndeavourOS, Garuda, CachyOS, Artix | `arch` |
| zypper      | openSUSE (Leap e Tumbleweed), SLES, SLED | `suse`, `opensuse` |
| portage     | Gentoo, Funtoo | `gentoo` |

Distros derivadas que não estão na lista costumam ser detectadas pelo `ID_LIKE`. Se nem isso funcionar, o script procura `apt-get`, `dnf`, `pacman`, `zypper` ou `emerge` no `PATH`.

## Requisitos

- Linux com bash 4+
- `sudo` (somente se você não rodar como root)
- Utilitários comuns: `sed`, `tr`, `readlink`, `install`

## Instalação

Baixe o arquivo `AutomaSystem.sh` e execute:

```bash
bash AutomaSystem.sh --install
```

Isso copia o script para `/usr/local/bin/AutomaSystem` com permissão de execução (pede senha do sudo se necessário). Para remover:

```bash
AutomaSystem --uninstall
```

Instalação manual, se preferir:

```bash
sudo install -m 755 AutomaSystem.sh /usr/local/bin/AutomaSystem
```

Também dá para rodar sem instalar: `bash AutomaSystem.sh`.

## Uso

```bash
AutomaSystem               # executa a manutenção padrão
AutomaSystem --dry-run     # mostra os comandos sem executar nada
AutomaSystem --full        # inclui tarefas marcadas como "risky"
AutomaSystem --install     # instala o comando em /usr/local/bin
AutomaSystem --uninstall   # remove o comando de /usr/local/bin
AutomaSystem --help        # mostra a ajuda
```

As opções `--dry-run` e `--full` podem ser combinadas. Recomendo rodar `AutomaSystem --dry-run` na primeira vez para conferir o que será feito no seu sistema.

### Exemplo de saída

```
Sistema: Ubuntu 24.04 LTS
Gerenciador de pacotes: apt

▶ Atualizar índice de pacotes
  $ sudo sh -c 'apt-get update'
...

──────── Resumo ────────
Total: 7 | Falhas: 0 | Ignoradas: 0
```

### Códigos de saída

| Código | Significado |
|--------|-------------|
| 0      | Todas as tarefas executadas com sucesso |
| 1      | Pelo menos uma tarefa falhou |
| 2      | Erro de uso ou distro não suportada |
| 130    | Interrompido pelo usuário (Ctrl+C) |

## O que cada gerenciador executa

| Gerenciador | Tarefas |
|-------------|---------|
| apt | `apt-get update`, `upgrade -y`, `autoremove -y`, `autoclean` |
| dnf | `upgrade --refresh -y`, `autoremove -y`, `clean packages` |
| pacman | `-Syu --noconfirm`, remoção de órfãos (`-Qtdq` / `-Rns`), `paccache -r`* |
| zypper | `refresh`, `update`, `clean` (todos com `--non-interactive`) |
| portage | `emerge --sync`, `--update --deep --newuse --with-bdeps=y @world`, `@preserved-rebuild`, `eclean-dist --deep`*, `emerge --depclean`** |

\* Só roda se a ferramenta estiver instalada (`paccache` vem do `pacman-contrib`; `eclean-dist` vem do `app-portage/gentoolkit`).
\*\* Só roda com `--full`.

Em todas as distros também são executadas estas tarefas comuns (quando as ferramentas existem):

- `journalctl --vacuum-time=7d`: limpa logs do journal com mais de 7 dias
- `systemctl --failed --no-pager`: lista serviços systemd com falha
- `df -h`: mostra o uso de disco

## Personalização

As tarefas ficam nas funções `load_tasks_<gerenciador>` dentro do script. Cada tarefa é uma chamada de `add_task`:

```bash
# add_task "descrição" "comando" ["binário requerido"] [risky: 0|1]
add_task "Limpar cache do Flatpak" "flatpak uninstall --unused -y" "flatpak"
add_task "Remover kernels antigos"  "meu-comando-perigoso" "" 1
```

- O **binário requerido** faz a tarefa ser ignorada se ele não existir no `PATH`.
- Passar `1` no último argumento marca a tarefa como arriscada (só roda com `--full`).
- Tarefas que valem para qualquer distro vão em `load_tasks_common`.

Para suportar um novo gerenciador de pacotes, crie uma função `load_tasks_<nome>` e adicione a distro nos `case` da função `detect_package_manager`.

## Avisos

- O script executa comandos como root. Leia a lista de tarefas e use `--dry-run` antes de confiar nele.
- As atualizações rodam sem confirmação (`-y`, `--noconfirm`, `--non-interactive`). Em distros rolling release, como Arch e Gentoo, atualizações automáticas podem exigir intervenção manual depois (arquivos de configuração, conflitos de pacotes, rebuilds).
- No Gentoo, `emerge --depclean` pode remover pacotes de que você precisa. Revise a lista com `emerge --depclean --pretend` antes de usar `--full`.
- O script não faz backup nem snapshot do sistema. Se isso for importante para você, crie um antes de rodar.

## Automação (opcional)

Para rodar diariamente, é possível usar um timer do systemd ou o cron do root. Exemplo de cron (todo dia às 04:00):

```
0 4 * * * /usr/local/bin/AutomaSystem >> /var/log/automasystem.log 2>&1
```

Como a execução automática dispensa confirmação, vale testar manualmente algumas vezes antes de agendar.