# macOS: 5 sn "Sürüyor" gecikmesini ve saatli logu derle ve dene

Bu dosyayı Mac'teki Claude Code oturumunda şöyle başlat: "`docs/handoffs/2026-11-02-macos-sure-gecikmesi-ve-saatli-log.md` dosyasındaki işi yap" (çalışma dizini `live-drive-ai`).

İş onaylı (kullanıcı, 2026-11-02, Linux oturumu). L anlaşma kontrolünü tekrarlama; yalnızca § "Durma koşulları"nda dur. Bitince kalıcı bilgiyi `docs/decisions.md`'ye (macOS bölümü) taşı ve bu dosyayı sil.

## Ne yapıldı (Linux'ta denendi, Mac'te yalnızca yazıldı, derlenmedi)

Commit `8f496bd`. Önce `git pull`, sonra `git show 8f496bd --stat` ve `docs/decisions.md` içindeki "Beş saniyelik gecikme ve saatli log" maddesini oku.

Neden: bir clipboard testinde (Linux) gösterge hesaplanan sürenin yalnızca %12'sinde "Sürüyor" dedi ve kullanıcının duraklatması testi durdurmadı. Claude işin çoğunu `send` dışından (kendi shell komutlarıyla) yapıyordu. Mac kodunda gösterge ve duraklatma aynı yerden çalıştığı için aynı açık orada da var; Mac'te yaşanmamasının nedeni kod değil, testlerin her şeyi `send` ile yapması.

`skill/macos/LiveDrive.swift` değişiklikleri:
- `stamp()` ve `log()`: her satır `HH:MM:SS ` ile başlıyor.
- `busyUntil` ve `driving`: batch bitince `busy` kapanıyor ama menü çubuğu 5 sn daha "Sürüyor" gösteriyor (`refresh()` 0,3 sn'de bir çalışıyor).

`skill/scripts/live-drive.py` (iki platform ortak): `body()` satırın başındaki saati atıyor; Mac'te `serve`'ün READY beklemesi ve `send`'in `END <id>` araması bunu kullanıyor.

## 1. Derle

`./install.sh`. Derleme hatası çıkarsa en olası yerler:
- `stamp()` içindeki `strftime(&buffer, ...)` ve `[Int8]` arabellek (macOS'ta `CChar` Int8, `tm`/`localtime_r` Foundation'dan gelmeli).
- `driving` hesaplanmış değişkeni ile `busy`'nin başka iş parçacığından okunması (zaten öncesinde de öyleydi, yarış sorunu çıkarsa kilitle).

Küçük düzeltmeyi yap, davranışı değiştirme.

## 2. Dene

1. `serve` başlat (arka planda). `~/.cache/live-drive.out` içindeki `READY` satırı saatle başlamalı, `serve`'ün kendi çıktısına `READY claude:<pid> serve <pid>` saatsiz yazılmalı ve `serve` bunu bekleyip takılmadan dönmeli (`READY` beklemesi `body()` ile eşleşiyor).
2. `send move:500,500 sleep:0.3` gönder: menü çubuğu hemen "Sürüyor", **batch bittikten ~5 sn sonra** "Bekliyor" demeli. (Ekran görüntüsüyle ya da `read_page`'le ölç, süreyi sayıyla yaz.)
3. `send` çıkış kodu 0 olmalı, çıktıda saatli satırlar görünmeli; yanlış bir adım (`send nope:1`) kodu ≠ 0 vermeli (`END <id> error ...` satırı saatli olsa da ayrıştırılıyor).
4. ⌃⌥⇧P ile duraklat: menü "Duraklatıldı" göstermeli (gecikme bunu bastırmamalı), sürdürünce yine "Sürüyor"/"Bekliyor".
5. **Bekleme sırasında kullanıcı algılama** (`8f496bd`den sonraki commit): `send focus:<pid> sleep:8` gönder, 2–3 sn sonra fareyi yarım saniye boyunca gerçekten oynat: menü çubuğu bekleme bitmeden "Sen kullanıyorsun" demeli, ⌃⌥⇧P ile sürdürünce `sleep` kalan süreyi bitirmeli. Tek kısa tıklama duraklatmamalı. Eskiden yalnızca bir sonraki tuşta duraklıyordu (Swift: `sleepStep` içinde `yieldToUser()`).
6. `quit` ile bitir; `check` hâlâ `all granted` demeli.

## Bitti ölçütü

- § 1 derlendi, § 2'deki beş madde geçti, ölçülen süre rapora yazıldı.
- `docs/decisions.md` macOS bölümüne tek satırlık "Mac'te de denendi, 5 sn ölçüldü" notu.
- Bu dosya silindi, `git push` yapıldı (bu klonda push adresi SSH olmalı: `git remote -v`).

## Durma koşulları

- Derleme `stamp()` dışındaki bir yerde patlıyorsa ya da gösterge 5 sn'den belirgin farklı kalıyorsa: düzeltmeden önce raporla.
- Menü çubuğunda "Sürüyor" hiç görünmüyorsa (Linux'ta çalışan mantık Mac'te çalışmıyor demektir): kullanıcıya sor.

## Rapor

**Senden beklenen**, **Değişenler**, **Bulunanlar** (ölçülen her şey sayıyla). Son satır **Sıradaki:**.
