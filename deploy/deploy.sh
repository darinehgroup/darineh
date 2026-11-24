#!/usr/bin/env bash
# استقرار darineh.com (لندینگ گروه دارینه) روی سرور دارینه — همان دستور بقیه‌ی سرویس‌ها:
#
#   ۱. خروجی ایستا همین‌جا ساخته می‌شود (python3 build.py → dist/)
#   ۲. با rsync به سرور می‌رود (زیر .incoming-<زمان>، بیرون از پوشه‌ای که Caddy سرو می‌کند)
#   ۳. روی سرور: نسخه‌ی فعلی سایت → backup/<زمان>/
#   ۴. سایت جایگزین می‌شود (Caddy همان پوشه را سرو می‌کند؛ ری‌استارت نمی‌خواهد)
#   ۵. آدرس عمومی چک می‌شود: باید ۲۰۰ بدهد و همان index.html تازه را
#
# استفاده:
#   deploy/deploy.sh                  بیلد + استقرار کامل
#   deploy/deploy.sh build            فقط بیلد محلی (برای تست)
#   deploy/deploy.sh status           وضعیت سایت روی سرور + استقرارهای قبلی
#   deploy/deploy.sh rollback <زمان>  بازگشت به backup/<زمان> (فهرست: status)
#   گزینه‌ها: --skip-build (همان dist/ فعلی فرستاده می‌شود)
#
# متغیرها: DEPLOY_SSH_TARGET (پیش‌فرض ubuntu@94.183.176.193)، DEPLOY_REMOTE_DIR (پوشه‌ی سایت روی
#          سرور؛ پیش‌فرض /opt/darineh/static)، KEEP_BACKUPS (پیش‌فرض ۵)، DEPLOY_SSH (دستور ssh سفارشی)
#
# پیش‌نیاز: python3، rsync، ssh با کلید (بدون رمز) به سرور.
set -euo pipefail

# ---------------------------------------------------------------- پیکربندی سرویس
SERVICE="darineh.com"
REMOTE_DIR_DEFAULT="/opt/darineh/static"   # همان پوشه‌ای که Caddy مشترک به‌جای /srv/static سرو می‌کند
HEALTH_URL="https://darineh.com/"          # آدرس عمومی برای چک نهایی
# -------------------------------------------------------------------------------

target=${DEPLOY_SSH_TARGET:-ubuntu@94.183.176.193}
remote_dir=${DEPLOY_REMOTE_DIR:-$REMOTE_DIR_DEFAULT}
# backup ها و releases.log کنار پوشه‌ی سایت می‌مانند، نه داخلش: هر چه داخل آن باشد عمومی سرو می‌شود.
state_dir=$remote_dir.deploy
keep=${KEEP_BACKUPS:-5}
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'deploy: %s\n' "$*" >&2; exit 1; }

# یک اتصال SSH برای همه‌ی دستورها
ssh_cmd=${DEPLOY_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=20 -o TCPKeepAlive=yes}
remote() { $ssh_cmd "$target" "$@"; }
rsync_to() { rsync -az --delete --partial --exclude .DS_Store -e "$ssh_cmd" "$@"; }

action=deploy; do_build=1; rb_ts=
for arg in "$@"; do
	case $arg in
	build|status|releases) action=$arg ;;
	rollback) action=rollback ;;
	--skip-build) do_build=0 ;;
	--frontend-only) ;; # این سرویس فقط فرانت است؛ برای یکدستی با بقیه پذیرفته می‌شود
	-h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*)
		if [[ $action == rollback && -z $rb_ts ]]; then rb_ts=$arg; else die "آرگومان ناشناخته: $arg (راهنما: --help)"; fi
		;;
	esac
done

build_site() {
	say "بیلد سایت (python3 build.py)"
	python3 build.py >/dev/null
	rm -f dist/.DS_Store
	[[ -s dist/index.html ]] || die "dist/index.html ساخته نشد"
	note "dist  ($(du -sh dist | cut -f1 | tr -d ' '))"
}

# health_check [sha]: آدرس عمومی باید ۲۰۰ بدهد؛ با sha، باید همان index.html را هم بدهد.
health_check() {
	local code served
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$HEALTH_URL" || echo 000)
	[[ $code == 200 ]] || { echo "deploy: $HEALTH_URL جواب $code داد (انتظار: 200)" >&2; return 1; }
	note "$HEALTH_URL -> $code"
	[[ -n ${1:-} ]] || return 0
	served=$(curl -s --max-time 20 "$HEALTH_URL" | shasum -a 256 | cut -d' ' -f1)
	[[ $served == "$1" ]] || { echo "deploy: $HEALTH_URL هنوز index.html تازه را نمی‌دهد" >&2; return 1; }
	note "همان index.html تازه سرو می‌شود"
}

case $action in
status|releases)
	remote "echo '--- سایت ($remote_dir) ---' && ls -la '$remote_dir' | tail -n +2 \
		&& echo && echo '--- استقرارهای قبلی (آخری پایین) ---' && (tail -n 10 '$state_dir/releases.log' 2>/dev/null || echo 'هنوز با این اسکریپت استقراری ثبت نشده') \
		&& echo && echo '--- backup ها ---' && (ls -1 '$state_dir/backup' 2>/dev/null | tail -n 10 || echo '-')"
	health_check
	exit 0 ;;
build)
	build_site
	say "خروجی در $root/dist"; exit 0 ;;
rollback)
	[[ -n $rb_ts ]] || die "زمانِ backup لازم است: deploy/deploy.sh rollback <زمان>  (فهرست: status)"
	say "بازگشت $SERVICE به backup/$rb_ts روی $target"
	remote "set -e; test -d '$state_dir/backup/$rb_ts' || { echo 'backup/$rb_ts وجود ندارد'; exit 1; }
		rsync -a --delete '$state_dir/backup/$rb_ts/' '$remote_dir/'
		echo \"\$(date +%Y%m%d-%H%M) rollback-to-$rb_ts\" >> '$state_dir/releases.log'"
	health_check
	say "بازگشت انجام شد."
	exit 0 ;;
deploy) ;;
esac

# ---------------------------------------------------------------- استقرار
ts=$(date +%Y%m%d-%H%M)
sha=$(git rev-parse --short HEAD 2>/dev/null || echo nogit)
branch=$(git branch --show-current 2>/dev/null || echo -)
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
	note "هشدار: تغییرات commit‌نشده در ریپو هست؛ همان‌ها استقرار می‌یابند."
	sha="$sha-dirty"
fi
say "استقرار $SERVICE ($branch @ $sha) روی $target:$remote_dir — نسخه $ts"
remote "test -d '$remote_dir'" || die "پوشه‌ی $remote_dir روی سرور نیست"

if [[ $do_build == 1 ]]; then
	build_site
else
	say "بیلد رد شد (--skip-build)؛ همان dist/ فرستاده می‌شود"
	[[ -s dist/index.html ]] || die "dist/index.html نیست"
fi
index_sha=$(shasum -a 256 dist/index.html | cut -d' ' -f1)

say "ارسال به سرور ($state_dir/.incoming-$ts)"
remote "mkdir -p '$state_dir/.incoming-$ts' '$state_dir/backup'"
rsync_to dist/ "$target:$state_dir/.incoming-$ts/"

say "روی سرور: backup و جایگزینی سایت"
remote "set -e; cd '$state_dir'
	mkdir -p backup/$ts && rsync -a --delete '$remote_dir/' backup/$ts/
	rsync -a --delete .incoming-$ts/ '$remote_dir/'
	rm -rf .incoming-$ts
	echo \"$ts $sha $branch \$(whoami)@\$(hostname)\" >> releases.log
	# نگه‌داری آخرین $keep backup
	ls -1d backup/*/ 2>/dev/null | sort | head -n -$keep | xargs -r rm -rf
	echo \"سایت جایگزین شد (\$(du -sh '$remote_dir' | cut -f1))\""

say "چک نهایی"
health_check "$index_sha"
say "$SERVICE نسخه $ts روی $target اجرا شد.  بازگشت: deploy/deploy.sh rollback $ts"
