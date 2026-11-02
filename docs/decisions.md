# Kararlar

Bir şeyi değiştirmeden önce burada gerekçesine bak. Tarihli maddeler yaşanmış bir olaya ya da
ölçüme dayanıyor; ölçmeden geri alma.

## Dağıtım

### Tek komutla kurulum: `install.sh` (2026-11-02)

Skill bağı, imza sertifikası, derleme ve izin kuralı tek betikte; elle kalan yalnızca macOS izinlerinin
anahtarını açmak. Elle yapılan her adım unutulabilir ve test ancak yarıda fark eder.

- **Skill symlink'le bağlanıyor, kopyalanmıyor:** `git pull` + `./install.sh` güncellemenin tamamı.
  `SKILL.md`'deki yollar (`~/.claude/skills/live-drive-desktop/...`) bu sayede değişmedi.
- **Claude Code eklentisi (plugin) değil:** eklentinin dizini sürüme göre değişiyor; Bash izin kuralı
  ve SKILL.md'deki sabit yol her güncellemede kırılırdı. LiveDrive.app'in derlenmesi de yine ayrı
  bir betik isterdi.
- **Var olan bir symlink değiştiriliyor, gerçek dizin değil:** symlink'i kaldırmak bir şey silmez,
  dizin ise birinin elle koyduğu kopya olabilir.

### İzin kuralını `install.sh` ekliyor, birleştirerek (2026-11-02)

`Bash(/usr/bin/python3 -I <ev>/.claude/skills/live-drive-desktop/scripts/live-drive.py:*)`. Kural
yoksa her `send` onay ister ve test akmaz. `~/.claude/settings.json` okunup listeye ekleniyor, öteki
anahtarlara dokunulmuyor; dosya symlink'se ya da okunamıyorsa yazılmıyor, kural ekrana basılıyor
(symlink'in arkası başka bir reponun dosyası olabilir). `--no-settings` bu adımı atlıyor.

### İmza sertifikası betikle, "güvenilir" işaretlenmeden (2026-11-02, ölçüldü)

TCC izni paket kimliğine ve imza gereksinimine bağlı. Geçici imzada gereksinim cdhash: her yeniden
derleme iki izni düşürür. Kendinden imzalı sertifikada gereksinim
`identifier "..." and certificate leaf = H"<parmak izi>"`, yani derlemeden derlemeye aynı.

Sertifikayı Anahtar Zinciri Erişimi'nde elle oluşturup "Her Zaman Güven" demek gerekmiyor.
Ölçülen (macOS 27.2): `openssl` ile üretilip `security import -T /usr/bin/codesign` ile alınan,
güvenilir işaretlenmemiş (`CSSMERR_TP_NOT_TRUSTED`) sertifikayla `codesign` imzalıyor, imza
`codesign --verify` ve kendi gereksinimini geçiyor, anahtar zinciri onay penceresi çıkmıyor.
Güven işaretlemek (`security add-trusted-cert`) parola penceresi açtığı için yapılmıyor. Bu yüzden
`security find-identity` **`-v` olmadan** aranıyor: `-v` yalnızca güvenilenleri listeliyor.

- `/usr/bin/openssl` (LibreSSL): Homebrew'un OpenSSL 3'ü `.p12`'yi `security import`'un okuyamadığı
  bir şifrelemeyle yazıyor.
- Sertifika kaybolur ya da yeniden üretilirse parmak izi değişir ve iki izin bir kez yeniden verilir.

### İzinler kurulumda, macOS'un kendi pencereleriyle (2026-11-02, ölçüldü)

`install.sh` son adımda `check` çalıştırıyor; eksik izin için macOS'un kendi penceresi ("Open System
Settings") çıkıyor ve LiveDrive listeye ekleniyor, kullanıcı yalnızca anahtarı açıyor. Sonra Enter
bekleyip yeniden denetliyor; hâlâ eksik olanın bölmesini yedek olarak `install.sh` açıyor.

- *Ekran Kaydı kaydı ikinci istekte oluşuyor (macOS 27.2, `tccd` günlüğü).* İlk
  `CGRequestScreenCaptureAccess` yalnızca bildiriyor ("does not allow prompting"), listeye kayıt
  eklemiyor; aynı uygulamanın ikinci isteğinde kayıt oluşuyor. Yalnızca `CGRequestScreenCaptureAccess` kullanan
  sürümde kayıt bu yüzden ancak ikinci `check`'te çıkıyordu. `check` artık ardından bir ScreenCaptureKit sorgusu da yapıyor: ikinci istek
  aynı çalıştırmada geliyor, kayıt ilk kurulumda oluşuyor (yeni yolda denendi, kullanıcı listede gördü).
- *Kimliği değişen uygulama aynı yolda kalırsa kayıt eski kimliğe yazılıyor.* Paket kimliği
  değiştikten sonra `~/Applications/LiveDrive.app`'in Ekran Kaydı isteği `tccd`'de eski kimlikle
  kaydedildi; o kimlik artık çözülemediği için Ayarlar listesinde görünmedi. `tccutil reset` eski kaydı
  silse de yenisi yine eski kimlikle oluştu, yani yol başına bir önbellek var. Aynı uygulama başka bir
  yoldan çalıştırılınca kayıt doğru kimlikle oluştu; izin kimlik + imzaya bağlı olduğu için asıl yoldaki
  uygulamaya da geçti. Yalnızca kimlik değiştiren güncellemede yaşanır; oturumu kapatıp açmak da
  önbelleği temizler (denenmedi).
- *Ayarlar açıkken eklenen kayıt listede hemen görünmeyebilir* (varsayım, ölçülmedi); deneme
  sırasında Ayarlar her seferinde kapatılıp açıldı.
- *Geçici dizindeki uygulama listede çıkmıyor:* LaunchServices onu çözmüyor (`tccutil`
  "No such bundle identifier"). Deneme uygulamasını `~/Applications` altına koy.

### Paket kimliği `io.github.smlblr.LiveDrive` (2026-11-02)

TCC izinleri bu kimliğe bağlı. Değişirse TCC uygulamayı yeni sayar: herkes iki izni yeniden verir ve
aynı yoldaki eski kimlik Ekran Kaydı kaydını gizleyebilir (yukarıda). Değiştirme.

## Skill

### Yalnızca Claude Code, yalnızca elle çağrı (2026-10-20)

Eski adı `live-desktop-test`; 2026-11-01'de `live-drive-desktop` oldu.

- **Yalnızca Claude Code.** Skill, Bash izin kuralına ve ekran görüntüsünü okuyup odağı doğrulayan
  bir döngüye dayanıyor; başka ajanlarda ölçülmedi.
- **`disable-model-invocation: true`.** Gerçek klavye/fare girdisi gönderiyor; model kendi kararıyla
  başlatmasın, istemeyen proje açıklamasını bile bağlamda taşımasın. `/live-drive-desktop`.
- **Odak kapısı kodda (2026-11-01).** Her girdi adımından önce etkin pencerenin PID'i, `focus:` ile
  verilen test sürecinin alt ağacında mı diye bakılıyor; tıklamadan sonra bir kez daha. "Her batch'ten
  önce ekran görüntüsüyle odağı doğrula" kuralı 2026-10-20'de sohbete `exit` yazılmasını önlemedi.
  Yön tek: izin verilen sürecin ATALARI kabul edilmiyor, `serve`'ün ataları da `focus:` olarak
  reddediliyor — test uygulamasının atası sohbetin kendisi. Birden fazla pencere ACTIVE görünürse
  (kapalı bir tarayıcı penceresi durumu bırakmamıştı) hepsinin izinli olması gerekiyor; yalnızca
  ilkine bakmak kapıyı yanlış pencereye açabilirdi.

### Tek sürücü ve kullanıcı önceliği (2026-11-02, canlı denendi)

- *Kilit (`~/.cache/live-drive.lock`, `flock`):* kilit yokken ikinci bir `serve` birincinin FIFO'sunu
  silip yeniden açıyordu; birinci her istekte dosyayı yeniden açtığı için ikisi aynı isteği okuyordu,
  bir oturumun tuşu öbürünün `focus:` listesiyle denetlenebiliyordu. Artık ikinci `serve`
  reddediliyor; `send`/`quit` da yalnızca kilidi tutan oturumdan kabul ediliyor. Oturum = en yakın
  `claude` ata süreci (bir oturumun bütün Bash çağrıları onun altında). Kuyruk yerine ret: saatlerce
  sessizce bekleyen bir oturum, açıkça reddedilenden kötü. Kilit Python ön yüzünde, macOS de aynı
  yoldan geçiyor.
- *Kullanıcı önceliği:* "kullanıyor" = 2 sn içinde en az üç ayrı 0,1 sn diliminde klavye ya da fare
  girdisi. İlk sürüm (yalnızca adımlardan önce, "son 3 sn'de tek girdi") canlı testte iki yönde de
  yanıldı: ardışık hızlı adımlarda bakılan pencere ~0'a iniyordu, kullanıcı görülmedi; batch başında
  tek bir kısa girdi (tıklama, fare sarsıntısı) testi durdurdu. Sahte kullanıcıyla ölçüldü: eski kod
  40 ms arayla iki olaydan ibaret bir patlamada durdu, yoğun batch ortasındaki 0,6 sn'lik kullanımı
  kaçırdı; yenisi ilkini yok sayıyor, ikincisini 0,16 sn'de yakalıyor. Boşta kalmasını beklemek
  yerine açık onay: oturum duraklayıp Ctrl+Alt+Shift+P (macOS ⌃⌥⇧P) istiyor (başlarken "Claude
  ekranı sürmek istiyor", ortada "Sen kullanıyorsun"). Kısayola basmak da girdi olduğu için
  sürdürmeden sonra 1 sn bu denetim yapılmıyor. Duraklarken basılı sentetik tuşlar bırakılıyor;
  yarıda kalan `drag` hata veriyor. Uzun duraklamada `send` 120 sn sonra "batch is waiting" diyor:
  batch kaybolmuyor, yeniden göndermek iki kez çalıştırırdı.
- *Girdi yokken duraklatma yok, gösterge "Bekliyor".* Hiç adım göndermeden açık duran bir oturum
  "Test sürüyor" gösterdi; dokunulduğu hâlde durmadığı için algılama bozuk sanıldı. Oturum açıkken
  her dokunuşta duraklatmak reddedildi: batch'ler arasında kullanıcı sohbeti okuyup yazıyor, her
  mesajdan sonra kısayol isterdi ve korunacak bir girdi yoktu. Bunun yerine gösterge batch sırasında
  "Sürüyor", arada "Bekliyor" yazıyor.
  - *Beş saniyelik gecikme ve saatli log (2026-11-02, Linux'ta ölçüldü, macOS'a aynı kod yazıldı,
    Mac'te denenmedi).* Bir clipboard testinde (53 batch, ~18 dk) gösterge hesaplanan sürenin yalnızca
    %12'sinde "Sürüyor" dedi: Claude testin büyük kısmını `send` dışında yürütüyordu (`coppy`
    komutuyla pencere açıp kapatmak, `systemctl restart`, ekran kaydı betiği). Gösterge artık son
    batch'ten 5 sn sonra "Bekliyor"a dönüyor. Duraklatma da yalnızca serve'ün adımlarını durduruyor; bu
    iki platformda aynı (Swift'te `gate()` aynı yerde bakıyor), Mac'te yaşanmamasının nedeni kod değil,
    o testlerin her şeyi `send` ile yapması. Kendi komutlarını da durduracak bir adım serve'e
    keyfi komut çalıştırma yetkisi vermek olurdu; bunun yerine SKILL.md `~/.cache/live-drive.pause`
    dosyasına bakmayı (`check` duraklatmayı yalnızca `warn` satırı olarak veriyor, son satır yine `all ok`) ve ekrana dokunan işi kısa batch'lerde tutmayı söylüyor (zorlama değil, uyum).
    `live-drive.out` satırları `HH:MM:SS ` ile başlıyor, böylece bir duraklatma o sırada çalışanla
    eşleştirilebiliyor; ayrıştıran kod (`send`, Mac'te READY beklemesi) saati atıyor.
- *Hazır sinyali.* `live-drive.out` bütün oturumların ortak dosyası; reddedilen `serve` önceki
  oturumun `READY`'sini orada bırakıyor ve başka bir oturum onu kendi sandı. Satır artık sahibini
  taşıyor (`READY claude:<pid> serve <pid>`) ve `serve`'ün kendi çıktısına da yazılıyor. Asıl
  doğrulama ilk `send`: sahibi denetliyor. Kilit yalnızca `send`'den geçeni kapsıyor; uygulama açmak
  ya da D-Bus ile pencere açtırmak kapsam dışı, o yüzden SKILL.md bunları ilk `send` başarılı olana
  kadar yasaklıyor.

## macOS: Swift yardımcısı LiveDrive.app (2026-11-01, canlı denendi)

- *Neden yalnızca açık arayüz:* CGEvent, ScreenCaptureKit, AXUIElement, sysctl, Carbon hot key,
  NSStatusItem, UserNotifications. SkyLight gibi özel arayüzler (arka planda girdi) her macOS
  güncellemesinde sessizce kırılabilir; arka planda girdi ve sanal ekran kapsam dışı.
- *Neden `.app` ve `open` ile başlatma:* TCC izni "sorumlu süreç"e yazılır; terminalden ya da
  Claude'dan doğrudan çalışan ikilinin izni onu başlatan uygulamaya gider. macOS 26.1'den beri komut
  satırı ikilisi Erişilebilirlik listesine eklenemiyor. `live-drive.py` ön yüz olarak kalıyor (tek
  izin kuralı, tek komut biçimi).
- *`--deny`:* `open` ile başlayan uygulamanın ebeveyni launchd; yardımcı kendi atalarından sohbeti
  bulamaz. Ön yüz kendi ata zincirini (Claude uygulaması dahil, ölçüldü) geçiriyor; bu süreçler
  `focus:` olarak reddediliyor ve öndeyse girdi `focus:any` altında bile gitmiyor. `--parent`: ön yüz
  ölünce yardımcı da kapanıyor (`open -W` ölse de uygulama yaşardı).
- *Klavye `postToPid` ile, kapıdan geçen sürece:* kapı denetimiyle olay arasındaki milisaniyede odak
  değişse de tuş izinli sürece gidiyor; sistemin genel tuş durumu etkilenmiyor (basılı `down:shift`
  kullanıcının klavyesine sızmadı, ölçüldü). TextEdit ve VS Code (Electron) yazıyor. Metin
  `keyboardSetUnicodeString` ile gidiyor: düzenden bağımsız, €/漢/emoji dahil düşen yok.
- *Kullanıcı önceliği: sayaç değil olay musluğu (2026-11-02).* `CGEventSource.secondsSinceLastEventType`
  bizim gönderdiğimiz fare/kaydırma olaylarıyla da sıfırlanıyor, ama 0,1–0,5 sn geç görünüyor ve olayı
  0,02–0,42 sn erken tarihliyor (7/7 ölçüm); "bizim son olayımızdan yeni" karşılaştırması bununla
  yanlış olurdu. Yerine yalnızca dinleyen bir `CGEvent` musluğu: her olayın
  `eventSourceUnixProcessID`'si var, bizimkiler LiveDrive'ın pid'ini taşıyor (11/11), Erişilebilirlik
  izni yetiyor. Musluk yalnızca "kullanıcının son girdi anı"nı tutuyor, liste her 0,1 sn'de
  örnekleniyor: olay başına saymak 0,16 sn'lik bir dürtmeyi kullanım saydı.
- *Güvenlik:* yardımcı çalıştığı sürece kullanıcının herhangi bir süreci FIFO'ya yazıp yardımcının
  izinleriyle girdi gönderebilir. Linux'ta Mutter D-Bus zaten herkese açık; macOS'ta yeni bir yetki.
  Sınırlar: yalnızca test süresince çalışır (daemon değil), FIFO 0600 ve açılışta `lstat` ile
  doğrulanır, odak kapısı girdiyi `focus:` süreçleriyle sınırlar.
- *Ölçülenler (macOS 27.2, Apple Silicon):* nokta çözünürlüğündeki görüntü (1470x956) okunuyor; doğal
  kaydırma sentetik kaydırmayı ters çevirmiyor; tıklamadan sonraki 0,15 sn odak denetimine yetiyor;
  ilk ekran görüntüsünde ayrıca "private window picker" izni soruluyor; Carbon kısayolları Türkçe
  düzende karakterle (s/p) kaydediliyor.

## Linux: GNOME Wayland

- *Mutter RemoteDesktop + ScreenCast, D-Bus üzerinden.* Ek izin penceresi ya da derleme yok.
- *Karakterler `xkb_utf32_to_keysym` ile çevriliyor (2026-11-01, canlı denendi).* Mutter tuşu etkin
  düzende arıyor ve düzen ğ/ş/ı'yı eski keysym'leriyle (`gbreve` 0x2bb) tanımlıyor; Unicode biçimi
  (0x100011f) sessizce düşüyordu. Düzende olmayan karakter (漢) yine düşüyor; hata dönmüyor.
- *`focus:any` sohbeti yine reddediyor (2026-11-02):* etkin pencerenin PID'i `serve`'ün ata
  zincirindeyse (Claude uygulaması orada) girdi gitmiyor; macOS'taki `--deny` ile aynı kural.
- *Uzun `type:` ve `drag` sırasında 0,2 sn'de bir yeniden denetim:* Mutter'da tuşu bir sürece
  yollamanın yolu yok, tuş öndeki pencereye gidiyor. Her karakterde sormak pahalı (AT-SPI sorgusu
  ~56 ms); 0,2 sn'de bir sormak, yazma ortasında öne gelen pencereye ölçülen kaçağı 1 karaktere
  indirdi. Kaçak sıfır değil; `SKILL.md` bunu söylüyor.
- *Kullanıcı önceliği:* Mutter IdleMonitor son girdiden geçen süreyi veriyor; bizim sentetik
  girdimiz de onu sıfırlıyor (11 sn → 0,1 sn), hem de D-Bus çağrısı dönmeden (40 denemede en geç
  +0,1 ms). Bu yüzden zamanı sorgudan *önce* alınan ve bizim son olayımızdan yeni olan girdi
  kullanıcının. Sayaç her 0,1 sn'de örnekleniyor.
- *Duraklat/durdur bildirimi:* GNOME'un yerleşik göstergesinde duraklatma durumu yok; `serve` bir
  bildirim gösteriyor: duraklatılmışken kritik (kapanana kadar ekranda), sürdürme ve durdurmada kısa.
  Oturum biterken `.pause` da siliniyor; kalırsa sonraki oturum duraklatılmış başlıyordu.
- *Üst çubuk simgesi: StatusNotifierItem + DBusMenu, Gio ile elle, paketsiz:*
  - GNOME Shell eklentisi değil: eklentiler GNOME sürümleriyle kırılıyor (45'te tümü), Wayland'de
    yeni eklenti oturumu yeniden açmadan yüklenmiyor.
  - Kütüphane değil: `libayatana-appindicator` "deprecated" basıyor ve GTK3 çekiyor; halefi
    `libayatana-appindicator-glib` menüyü `org.gtk.Menus` olarak yayınlıyor, Ubuntu'nun
    `ubuntu-appindicators` eklentisi yalnızca `com.canonical.dbusmenu` okuyor — menü hiç görünmedi.
  - Protokollerin kendisi (SNI, DBusMenu) ~150 satır, bağımlılık yok. Watcher yoksa (eklenti kapalı)
    simge çıkmıyor, test çalışmaya devam ediyor. `Activate` yöntemi bilerek yok: eklenti o zaman sol
    tıkta menüyü açıyor.
- *Durdur/duraklat kısayolları komutlarına göre aranıyor (2026-11-02).* GNOME özel kısayolları bir
  liste + yol başına ayar. Başka bir kurulum betiği listeyi baştan yazıyorsa `install.sh`'nin
  eklediği yolları düşürür; o betik kısayolları kendi listesine koymalı. `install.sh` aynı komutla
  tanımlı bir kısayol bulursa (yolu ne olursa olsun) yenisini eklemiyor, çift tanım olmuyor.
- *KDE ve X11 kapsam dışı.* 2026-11-01 araştırması: KDE portalı `persist_mode=2` ve sabit uygulama
  kimliğiyle tek onayla çalışıyor; iş açık.
