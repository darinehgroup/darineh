# راهنمای دیپلوی لندینگ گروه دارینه (darineh.com)

این مخزن شامل صفحه لندینگ رسمی گروه دارینه (`https://darineh.com`) است.

---

## معماری دامنه‌ها

بر اساس توافقات معماری گروه دارینه (`discusion.md`):
- `darineh.com` و `www.darineh.com`: لندینگ اصلی گروه (معرفی محصولات، بدون لاگین و سشن).
- `login.darineh.com` و `id.darineh.com`: سامانه احراز هویت متمرکز **Darineh ID** (پورت ۸۰۸۰ دارینه‌آیدی).
- `pay.darineh.com`: سامانه متمرکز پرداخت **Darineh Pay** (پورت ۸۰۸۰ درگاه و ۸۰۸۱ ادمین).
- `admin.rasad.darineh.com` و `app.rasad.darineh.com`: سامانه **رصد**.

> **نکته مهم:** دامنه اصلی `darineh.com` نباید به بک‌اند Darineh ID پروکسی شود؛ بلکه باید فایل‌های خروجی استاتیک `ui/dist` را مستقیماً سرو کند.

---

## مراحل بیلد و استقرار

### ۱. بیلد فایل‌های استاتیک
```bash
cd ui
python3 build.py
```
خروجی در مسیر `ui/dist` (شامل `index.html`, `assets/`, `fonts/`, `robots.txt`) تولید می‌شود.

### ۲. کپی به مسیر سرور (مثلاً `/srv/darineh-landing`)
```bash
sudo mkdir -p /srv/darineh-landing
sudo cp -r ui/dist/* /srv/darineh-landing/
sudo chown -R caddy:caddy /srv/darineh-landing
```

### ۳. تنظیم Caddy
بلوک زیر را به فایل `/etc/caddy/Caddyfile` سرور اضافه نموده و Caddy را ریلود کنید:

```caddy
(darineh_landing_security) {
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        X-Frame-Options "SAMEORIGIN"
        Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data: https:; object-src 'none'; base-uri 'self'; frame-ancestors 'self'"
        -Server
    }
}

darineh.com {
    import darineh_landing_security

    encode zstd gzip
    root * /srv/darineh-landing

    @static {
        file
        path *.ico *.png *.svg *.woff2 *.css *.js *.txt
    }
    header @static Cache-Control "public, max-age=604800, stale-while-revalidate=86400"

    @html {
        path / /index.html
    }
    header @html Cache-Control "no-cache"

    file_server
    try_files {path} /index.html
}

www.darineh.com {
    redir https://darineh.com{uri} permanent
}
```

سپس در سرور:
```bash
sudo systemctl reload caddy
```
