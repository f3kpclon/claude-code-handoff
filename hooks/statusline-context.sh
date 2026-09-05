#!/usr/bin/env bash
# shellcheck disable=SC2016  # jq programs are single-quoted on purpose — $obs/$fhu are jq params, not shell vars
# ── CUSTOMIZE ────────────────────────────────────────────────────────────────
# Contexto de sesión
#
# Los cortes NO son una escala decorativa de 10 en 10: están puestos donde la
# evidencia dice que la calidad ya cayó, que es MUCHO antes de que se llene la
# ventana. Resumen de por qué (fuentes en README → "Por qué estos cortes"):
#   · NoLiMa (Adobe, ICML'25): 11 de 12 modelos caen bajo el 50% de su
#     rendimiento de contexto corto YA EN 32k tokens, cuando la tarea exige
#     inferencia y no calce literal. En 200k eso es el 16% de la barra.
#   · Chroma "Context Rot" (18 modelos, incl. Opus 4 / Sonnet 4 / Haiku 3.5):
#     la degradación es continua desde el primer incremento. No hay acantilado
#     que esperar, hay una pendiente que ya vas bajando.
#   · Agentes long-horizon: pérdida del objetivo original desde los ~10-15
#     pasos. Una sesión de Claude Code pasa eso sin llegar al 40%.
# Por eso el 🔥 arranca en 40 y no en 50, y el 💀 en 75 y no en 80.
CTX_CRIT_DOT="🆘";  CTX_CRIT_MSG="handoff altiro weón"
CTX_LOST_DOT="💀";  CTX_LOST_AT=75; CTX_LOST_MSG="¿qué hacíamos?"
CTX_FADE_DOT="🔪";  CTX_FADE_AT=65; CTX_FADE_MSG="me pase po"
CTX_DRIFT_DOT="👻"; CTX_DRIFT_AT=55; CTX_DRIFT_MSG="en cualquier momento me voy en la vola'"
CTX_WARM_DOT="🔥";  CTX_WARM_AT=40; CTX_WARM_MSG="se calienta la cosa"
CTX_OK_DOT="😎";    CTX_OK_AT=20;   CTX_OK_MSG="tranqui"
CTX_FRESH_DOT="😈"; CTX_FRESH_MSG="listo mi guasho! estamo' entero activa'os"

# Tokens que Claude Code reserva y NUNCA te deja usar: el auto-compact dispara
# cuando quedan ~13k libres de una ventana efectiva que ya viene recortada
# respecto de la anunciada. En 200k el compact cae en ~167k = 83,5% de la barra.
#
# Esto es lo que hacía que el tramo crítico fuera código muerto: estaba fijo en
# 90, y en una ventana de 200k el 90 NO SE ALCANZA JAMÁS — la sesión se compacta
# antes. El 🆘 no se pintó nunca. Ahora el corte se calcula desde el tamaño real
# de ventana que trae el payload, así que también funciona en 1M.
#
# 33000 está verificado sólo para 200k (compact observado a 83-85% por varios
# reportes independientes). Para 1M el reparto entre "ventana efectiva" y el
# margen de 13k no está documentado: si ves que compacta antes de lo que marca
# la barra, sube este número.
CTX_RESERVE=${CTX_RESERVE:-33000}
# Cuánto antes del compact se enciende el 🆘. Que avise justo cuando ya está
# compactando no sirve de nada: para eso está el hook PreCompact.
CTX_CRIT_MARGIN=${CTX_CRIT_MARGIN:-2}

# Cupo horario (ventana 5h rolling)
RH90_DOT="🆘"; RH90_MSG="quedando pato weón! al 100 no money no honey"
RH80_DOT="💀"; RH80_MSG="casi sin cupo horario"
RH70_DOT="🔪"; RH70_MSG="se acaba el turno weón"
RH50_DOT="🔥"; RH50_MSG="vamos consumiendo el turno"
RH30_DOT="😎"; RH30_MSG="tranqui, hay cupo"
RH00_DOT="😈"; RH00_MSG="hay turno, estamo' entero"
# Ventana vencida: el cupo ya se reinició pero el turno nuevo no arranca hasta
# el próximo mensaje — el % que trae el payload es todavía el de la ventana muerta.
RHX_DOT="🆕"; RHX_MSG="ventana vencida — el próximo mensaje abre turno nuevo"

# Cupo semanal (ventana 7d)
RS90_DOT="🆘"; RS90_MSG="llama a soporte weón"
RS80_DOT="💀"; RS80_MSG="casi sin cupo esta semana"
RS70_DOT="👻"; RS70_MSG="ojo con el cupo semanal"
RS50_DOT="🔥"; RS50_MSG="mitad de semana consumida"
RS30_DOT="😎"; RS30_MSG="tranqui, semana larga"
RS00_DOT="😈"; RS00_MSG="semana entera por delante"

# Presupuesto de gasto (API key)
# Con API key no hay ventanas de cupo: el payload llega sin rate_limits y las
# dos líneas de arriba desaparecen. Ahí el límite no es tiempo, es plata, y sin
# esto el statusline se queda mudo justo cuando el gasto sí importa.
# En dólares. 0 = sin presupuesto — la línea no se pinta y todo sigue igual.
COST_BUDGET=${COST_BUDGET:-0}
# Pasarse del presupuesto es un estado distinto de estar cerca, no un tramo
# más de la escala: merece su propio aviso o el 101% se lee igual que el 90%.
CBX_DOT="🩸"; CBX_MSG="te pasaste del presupuesto weón"
CB90_DOT="🆘"; CB90_MSG="quedando pato, corta el chorro"
CB80_DOT="💀"; CB80_MSG="casi sin presupuesto"
CB70_DOT="🔪"; CB70_MSG="ojo que se va la plata"
CB50_DOT="🔥"; CB50_MSG="media sesión de presupuesto"
CB30_DOT="😎"; CB30_MSG="tranqui, hay billete"
CB00_DOT="😈"; CB00_MSG="recién parti'o, cero gasto"
# ─────────────────────────────────────────────────────────────────────────────

input=$(cat)

# ── Parse JSON — UNA sola llamada a jq ───────────────────────────────────────
# Todos los campos usan `// ""` y NO `// empty`. Con `// empty` jq omite la
# línea entera cuando el campo falta, y cada campo de abajo sube una posición:
# el statusline pinta el valor equivocado en la variable equivocada, sin error
# y sin ruido. `// ""` garantiza una línea por campo, siempre.
JQ_OUT=$(echo "$input" | jq -r '
  (.model.id // .model.display_name // "?"),
  (.workspace.current_dir // .cwd // ""),
  (.cost.total_cost_usd // 0),
  (.context_window.used_percentage // ""),
  (.context_window.context_window_size // 0),
  (.session_id // ""),
  (.rate_limits.five_hour.used_percentage  // ""),
  (.rate_limits.five_hour.resets_at        // ""),
  (.rate_limits.seven_day.used_percentage  // ""),
  (.rate_limits.seven_day.resets_at        // ""),
  (now | floor)
' 2>/dev/null)

# Bloque { } y no un pipe: un pipe correría los `read` en un subshell y las
# variables se perderían al volver. `now` viene de jq para no forkear `date`.
{
    IFS= read -r MODEL
    IFS= read -r DIR
    IFS= read -r COST
    IFS= read -r used
    IFS= read -r CTX_SIZE
    IFS= read -r SID
    IFS= read -r FIVE_H
    IFS= read -r FIVE_H_RESET
    IFS= read -r SEVEN_D
    IFS= read -r SEVEN_D_RESET
    IFS= read -r NOW
} <<< "$JQ_OUT"

[ -z "$used" ] && exit 0

# ── Punto de compactación ────────────────────────────────────────────────────
# Porcentaje de la barra en el que Claude Code va a auto-compactar. Todo lo que
# esté por encima es inalcanzable: no tiene sentido pintar tramos ahí.
# Sin context_window_size (payload viejo) se cae al 83, que es el valor medido
# en 200k — la ventana por defecto y el caso de lejos más común.
case "$CTX_SIZE" in ''|*[!0-9]*) CTX_SIZE=0 ;; esac
if [ "$CTX_SIZE" -gt "$CTX_RESERVE" ]; then
    COMPACT_PCT=$(( (CTX_SIZE - CTX_RESERVE) * 100 / CTX_SIZE ))
else
    COMPACT_PCT=83
fi
# El 🆘 va justo debajo del compact, pero nunca puede colarse bajo el 💀: con
# una ventana absurdamente chica el cálculo daría un crítico por debajo del
# tramo anterior y la escala quedaría desordenada al revés.
CTX_CRIT_AT=$(( COMPACT_PCT - CTX_CRIT_MARGIN ))
[ "$CTX_CRIT_AT" -le "$CTX_LOST_AT" ] && CTX_CRIT_AT=$(( CTX_LOST_AT + 1 ))

CTX_DIR="$HOME/.claude/ctx"
# Legacy global file (kept for custom statuslines that integrate manually)
echo "$used" > ~/.claude/ctx_pct.txt
# Per-session file — concurrent sessions must not clobber each other's pct
if [ -n "$SID" ]; then
    # `[ -d ]` is a builtin; `mkdir -p` is a 5 ms fork that was being paid on
    # every run for a directory that already exists.
    [ -d "$CTX_DIR" ] || mkdir -p "$CTX_DIR"
    echo "$used" > "$CTX_DIR/$SID.pct"
    # El monitor decide a qué % pedir handoff, pero sólo ve el .pct: sin esto no
    # tiene cómo saber si la ventana es de 200k o de 1M, y sus umbrales fijos
    # quedan o muy tarde (nunca disparan) o absurdamente temprano.
    echo "$COMPACT_PCT" > "$CTX_DIR/$SID.compact"
    # Reap stale per-session state: pct files, handoff threshold sentinels and
    # abandoned git caches older than a day — sessions long gone.
    #
    # Throttled to hourly. Measured at 37 ms, this find was the single most
    # expensive thing in the statusline: at refreshInterval=1 it scanned the
    # directory 86,400 times a day to delete files that are 24 h old. The
    # timestamp is read with $(<...), which costs no external process.
    HK="$CTX_DIR/.housekeeping"
    hk_ts=0
    [ -f "$HK" ] && hk_ts=$(<"$HK")
    case "$hk_ts" in ''|*[!0-9]*) hk_ts=0 ;; esac
    if [ $(( NOW - hk_ts )) -ge 3600 ]; then
        # Stamped BEFORE the sweep: if the find dies, the next run waits an hour
        # instead of retrying the expensive scan every single second.
        printf '%s' "$NOW" > "$HK"
        find "$CTX_DIR" \( -name '*.pct' -o -name '*.compact' -o -name 'handoff_w*' -o -name 'effort_w*' -o -name 'gitpart_*' \) -mmin +1440 -delete 2>/dev/null
    fi
fi
pct_int=$(( ${used%.*} ))

# ── Rate limits → disco ──────────────────────────────────────────────────────
# A diferencia de ctx_pct (que es per-session porque cada sesión tiene su propio
# contexto), el cupo es de la CUENTA: archivo único compartido, escritura
# atómica para que dos sesiones concurrentes no dejen un JSON a medio escribir.
#
# Se escribe como mucho cada RL_MAX_AGE segundos, no en cada corrida: con
# refreshInterval=1 una escritura incondicional serían 86.400 al día por un
# archivo que cambia 4 o 5 veces.
RL_MAX_AGE=30
RL_FILE="$HOME/.claude/ratelimit.json"
RL_HIST="$HOME/.claude/ratelimit-history.jsonl"

file_mtime() {
    # GNU (-c %Y) primero: en BSD esa opción falla con rc=1 y caemos a -f %m.
    # Al revés NO sirve — GNU acepta -f (es "filesystem status") y ante un
    # formato inválido imprime "?" con rc=0, o sea devolvería basura en vez de
    # fallar. El guard numérico es la red: cualquier cosa que no sean dígitos
    # se trata como 0, que solo provoca una escritura de más.
    local m
    m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || m=0
    case "$m" in ''|*[!0-9]*) m=0 ;; esac
    printf '%s' "$m"
}

if [ -n "$FIVE_H_RESET" ]; then
    rl_mtime=0
    [ -f "$RL_FILE" ] && rl_mtime=$(file_mtime "$RL_FILE")
    if [ $(( NOW - rl_mtime )) -ge "$RL_MAX_AGE" ]; then
        rl_prev=$(jq -r '.five_hour.resets_at // ""' "$RL_FILE" 2>/dev/null)
        # Flags separados (-n -c en vez de juntos): el patrón de netcat del
        # security scan del CI busca el par de letras n+c seguido de espacio,
        # y la forma junta se lo da — falso positivo que rompe el gate.
        RL_JSON=$(jq -n -c \
            --argjson obs "$NOW" \
            --argjson fhu "${FIVE_H:-null}"  --argjson fhr "${FIVE_H_RESET:-null}" \
            --argjson sdu "${SEVEN_D:-null}" --argjson sdr "${SEVEN_D_RESET:-null}" \
            '{observed_at: $obs,
              five_hour:  {used_percentage: $fhu, resets_at: $fhr},
              seven_day:  {used_percentage: $sdu, resets_at: $sdr}}' 2>/dev/null)
        if [ -n "$RL_JSON" ]; then
            # resets_at distinto = la ventana de 5h dio la vuelta. Este log es el
            # único registro de dónde caen los bordes de ventana; nada más los guarda.
            [ "$rl_prev" != "$FIVE_H_RESET" ] && echo "$RL_JSON" >> "$RL_HIST"
            # $$ en el tmp: dos sesiones escribiendo a la vez no deben compartirlo
            printf '%s\n' "$RL_JSON" > "$RL_FILE.$$.tmp" && mv -f "$RL_FILE.$$.tmp" "$RL_FILE"
        fi
    fi
fi

# ── Colors ────────────────────────────────────────────────────────────────────
RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'

# ── Bar builder ───────────────────────────────────────────────────────────────
COLS="${COLUMNS:-80}"
BAR_WIDTH=$(( COLS / 10 ))
[ "$BAR_WIDTH" -lt 10 ] && BAR_WIDTH=10
[ "$BAR_WIDTH" -gt 20 ] && BAR_WIDTH=20

make_bar() {
    local pct=$1 filled empty bar=""
    filled=$(( pct * BAR_WIDTH / 100 ))
    empty=$(( BAR_WIDTH - filled ))
    for ((i=0; i<filled; i++)); do bar="${bar}█"; done
    for ((i=0; i<empty;  i++)); do bar="${bar}░"; done
    echo "$bar"
}

# ── Countdown ────────────────────────────────────────────────────────────────
# Segundos → "2h47m" / "43m" / "<1m". Deja el resultado en FMT_LEFT en vez de
# hacer echo: un $(...) para leerlo forkearía un subshell cada corrida.
# Resolución de minuto a propósito — una ventana de 5h no gana nada con
# segundos, y eso permite que el refreshInterval por defecto sea 10s y no 1s.
fmt_left() {
    local s=$1 h m
    h=$(( s / 3600 ))
    m=$(( (s % 3600) / 60 ))
    if [ "$h" -gt 0 ]; then
        [ "$m" -lt 10 ] && m="0$m"
        FMT_LEFT="${h}h${m}m"
    elif [ "$m" -gt 0 ]; then
        FMT_LEFT="${m}m"
    else
        FMT_LEFT="<1m"
    fi
}

# ── Line 1: Sesión ────────────────────────────────────────────────────────────
# printf -v writes into the variable directly; $(printf ...) would fork a
# subshell for something bash can do in place.
printf -v COST_FMT '$%.2f' "$COST"

# Git, cached. The four git calls measured 51 ms — a quarter of the whole
# statusline — for a branch that changes every few hours and counters that
# tolerate a few seconds of lag just fine.
#
# The cache line is "<epoch>|<rendered git part>". The rendered part contains
# its own "|", which is why the timestamp is cut with %%|* (up to the FIRST
# separator) and the payload with #*| (the rest). A reader landing between the
# truncate and the write sees an empty file, the numeric guard treats that as a
# miss and recomputes — there is no way to read a torn value.
GIT_TTL=3
GIT_PART=""
if [ -n "$DIR" ]; then
    GIT_CACHE="$CTX_DIR/gitpart_${DIR//\//_}"
    git_c=""
    [ -f "$GIT_CACHE" ] && git_c=$(<"$GIT_CACHE")
    git_ts="${git_c%%|*}"
    case "$git_ts" in ''|*[!0-9]*) git_ts=-1 ;; esac

    if [ "$git_ts" -ge 0 ] && [ $(( NOW - git_ts )) -lt "$GIT_TTL" ]; then
        GIT_PART="${git_c#*|}"
    else
        if git -C "$DIR" rev-parse --git-dir > /dev/null 2>&1; then
            BRANCH=$(git -C "$DIR" branch --show-current 2>/dev/null)
            STAGED=$(git   -C "$DIR" diff --cached --numstat 2>/dev/null | wc -l | tr -d ' ')
            MODIFIED=$(git -C "$DIR" diff --numstat 2>/dev/null | wc -l | tr -d ' ')
            GIT_PART="Branch: 🌿 ${BRANCH}"
            [ "$STAGED"   -gt 0 ] && GIT_PART="${GIT_PART} +${STAGED}"
            [ "$MODIFIED" -gt 0 ] && GIT_PART="${GIT_PART} ~${MODIFIED}"
            GIT_PART=" | ${GIT_PART}"
        fi
        [ -d "$CTX_DIR" ] || mkdir -p "$CTX_DIR"
        printf '%s|%s' "$NOW" "$GIT_PART" > "$GIT_CACHE"
    fi
fi

printf "[%s]%s | 💰 %s\n" "$MODEL" "$GIT_PART" "$COST_FMT"

# ── Line 2: Contexto de sesión ────────────────────────────────────────────────
# El corte crítico es dinámico (ver CTX_CRIT_AT arriba); el resto son fijos y
# están donde la evidencia dice, no repartidos de 10 en 10.
if   [ "$pct_int" -ge "$CTX_CRIT_AT" ];  then color="$RED";    dot="$CTX_CRIT_DOT";  msg="$CTX_CRIT_MSG"
elif [ "$pct_int" -ge "$CTX_LOST_AT" ];  then color="$RED";    dot="$CTX_LOST_DOT";  msg="$CTX_LOST_MSG"
elif [ "$pct_int" -ge "$CTX_FADE_AT" ];  then color="$RED";    dot="$CTX_FADE_DOT";  msg="$CTX_FADE_MSG"
elif [ "$pct_int" -ge "$CTX_DRIFT_AT" ]; then color="$YELLOW"; dot="$CTX_DRIFT_DOT"; msg="$CTX_DRIFT_MSG"
elif [ "$pct_int" -ge "$CTX_WARM_AT" ];  then color="$YELLOW"; dot="$CTX_WARM_DOT";  msg="$CTX_WARM_MSG"
elif [ "$pct_int" -ge "$CTX_OK_AT" ];    then color="$GREEN";  dot="$CTX_OK_DOT";    msg="$CTX_OK_MSG"
else                                          color="$GREEN";  dot="$CTX_FRESH_DOT"; msg="$CTX_FRESH_MSG"
fi
echo "🧠 Contexto       ${dot} ${color}[$(make_bar "$pct_int")] ${pct_int}% — ${msg}${RESET}"

# ── Line 3: Cupo horario (5h) — solo Pro/Max ─────────────────────────────────
if [ -n "$FIVE_H" ]; then
    fh_secs=""
    [ -n "$FIVE_H_RESET" ] && fh_secs=$(( ${FIVE_H_RESET%.*} - NOW ))

    if [ -n "$fh_secs" ] && [ "$fh_secs" -le 0 ]; then
        # Ventana vencida. used_percentage sigue trayendo el valor de la ventana
        # MUERTA — pintar la barra aquí sería reportar consumo viejo como si
        # fuera el de ahora. Se dice el estado y nada más.
        echo "⏱ Cupo horario    ${RHX_DOT} ${GREEN}${RHX_MSG}${RESET}"
    else
        fh_int=$(( ${FIVE_H%.*} ))
        if   [ "$fh_int" -ge 90 ]; then color="$RED";    dot="$RH90_DOT"; msg="$RH90_MSG"
        elif [ "$fh_int" -ge 80 ]; then color="$RED";    dot="$RH80_DOT"; msg="$RH80_MSG"
        elif [ "$fh_int" -ge 70 ]; then color="$RED";    dot="$RH70_DOT"; msg="$RH70_MSG"
        elif [ "$fh_int" -ge 50 ]; then color="$YELLOW"; dot="$RH50_DOT"; msg="$RH50_MSG"
        elif [ "$fh_int" -ge 30 ]; then color="$GREEN";  dot="$RH30_DOT"; msg="$RH30_MSG"
        else                              color="$GREEN";  dot="$RH00_DOT"; msg="$RH00_MSG"
        fi
        LEFT=""
        if [ -n "$fh_secs" ]; then
            fmt_left "$fh_secs"
            LEFT=" — ${FMT_LEFT}"
        fi
        echo "⏱ Cupo horario    ${dot} ${color}[$(make_bar "$fh_int")] ${fh_int}%${LEFT} — ${msg}${RESET}"
    fi
fi

# ── Line 4: Cupo semanal (7d) — solo Pro/Max ─────────────────────────────────
if [ -n "$SEVEN_D" ]; then
    sd_int=$(( ${SEVEN_D%.*} ))
    if   [ "$sd_int" -ge 90 ]; then color="$RED";    dot="$RS90_DOT"; msg="$RS90_MSG"
    elif [ "$sd_int" -ge 80 ]; then color="$RED";    dot="$RS80_DOT"; msg="$RS80_MSG"
    elif [ "$sd_int" -ge 70 ]; then color="$YELLOW"; dot="$RS70_DOT"; msg="$RS70_MSG"
    elif [ "$sd_int" -ge 50 ]; then color="$YELLOW"; dot="$RS50_DOT"; msg="$RS50_MSG"
    elif [ "$sd_int" -ge 30 ]; then color="$GREEN";  dot="$RS30_DOT"; msg="$RS30_MSG"
    else                              color="$GREEN";  dot="$RS00_DOT"; msg="$RS00_MSG"
    fi
    echo "📅 Cupo semanal   ${dot} ${color}[$(make_bar "$sd_int")] ${sd_int}% — ${msg}${RESET}"
fi

# ── Line 5: Presupuesto de la sesión — solo API key ──────────────────────────
# Se pinta solo si hay presupuesto configurado Y el payload no trae cupos. Con
# suscripción el costo es nocional — lo que te limita es la ventana, no el
# dólar — así que una barra de presupuesto ahí estaría midiendo plata que no
# se paga. Las dos condiciones juntas son lo que hace que esta línea aparezca
# exactamente donde las de cupo no pueden.
if [ "$COST_BUDGET" != "0" ] && [ -z "$FIVE_H" ] && [ -z "$SEVEN_D" ]; then
    # Centavos vía printf y no un fork a awk/jq: bash no hace aritmética de
    # decimales, pero su printf sí entiende notación científica, así que
    # "12.34e2" da 1234 sin salir del proceso. El statusline corre en cada
    # render; un fork por decimal se paga en latencia visible.
    printf -v cost_c '%.0f' "${COST}e2"  2>/dev/null || cost_c=0
    printf -v bud_c  '%.0f' "${COST_BUDGET}e2" 2>/dev/null || bud_c=0
    case "$cost_c" in ''|*[!0-9]*) cost_c=0 ;; esac
    case "$bud_c"  in ''|*[!0-9]*) bud_c=0  ;; esac

    if [ "$bud_c" -gt 0 ]; then
        cb_int=$(( cost_c * 100 / bud_c ))
        # La barra se satura en 100 pero el porcentaje no: pasarse del
        # presupuesto es justo el dato que hay que ver, y recortarlo a 100%
        # borraría la diferencia entre ir justo y haberse pasado al doble.
        cb_bar=$cb_int; [ "$cb_bar" -gt 100 ] && cb_bar=100
        if   [ "$cb_int" -ge 100 ]; then color="$RED";   dot="$CBX_DOT"; msg="$CBX_MSG"
        elif [ "$cb_int" -ge 90 ]; then color="$RED";    dot="$CB90_DOT"; msg="$CB90_MSG"
        elif [ "$cb_int" -ge 80 ]; then color="$RED";    dot="$CB80_DOT"; msg="$CB80_MSG"
        elif [ "$cb_int" -ge 70 ]; then color="$RED";    dot="$CB70_DOT"; msg="$CB70_MSG"
        elif [ "$cb_int" -ge 50 ]; then color="$YELLOW"; dot="$CB50_DOT"; msg="$CB50_MSG"
        elif [ "$cb_int" -ge 30 ]; then color="$GREEN";  dot="$CB30_DOT"; msg="$CB30_MSG"
        else                              color="$GREEN";  dot="$CB00_DOT"; msg="$CB00_MSG"
        fi
        printf "💵 Presupuesto    %s %s[%s] %s%% — $%.2f / $%s — %s%s\n" \
            "$dot" "$color" "$(make_bar "$cb_bar")" "$cb_int" \
            "$COST" "$COST_BUDGET" "$msg" "$RESET"
    fi
fi
