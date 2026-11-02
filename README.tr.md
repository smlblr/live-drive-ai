# live-drive-ai

[English](README.md) · **Türkçe**

[Claude Code](https://claude.com/claude-code)'un, geliştirdiğin uygulamayı **senin canlı masaüstünde**
test etmesini sağlar. Claude, uygulamayı ayrı bir test penceresinde açar; klavyeyi ve fareyi kullanır,
ekran görüntüsü alıp sonucu kendisi okur. Sen bu sırada makineni kullanmaya devam edebilirsin: klavyeye
ya da fareye dokunduğunda test durur ve senin onayını bekler.

- **macOS 14+** — kurulumda derlenen küçük bir yardımcı uygulama (`LiveDrive.app`) kullanır. Yalnızca
  Apple'ın açık arayüzleri: CGEvent, ScreenCaptureKit, Erişilebilirlik.
- **Linux, GNOME Wayland** — GNOME'un kendi uzak masaüstü arayüzünü (Mutter RemoteDesktop/ScreenCast,
  D-Bus) kullanır; derlenecek bir şey yok. KDE ve X11 desteklenmiyor.

## Güvenlik önlemleri

Gerçek girdi gönderen bir araç, yanlış pencereye yazarsa zarar verebilir. Bu yüzden:

- **Odak kapısı.** Her tuş ve tıklamadan önce öndeki pencerenin, Claude'un açtığı test uygulamasına ait
  olup olmadığına bakılır. Değilse batch durur ve hangi pencereyi bulduğunu söyler. Claude'un kendi
  sohbet penceresine hiçbir koşulda girdi gitmez.
- **Önce sen.** Test sırasında klavyeyi ya da fareyi kullanmaya başlarsan test duraklar ("Sen
  kullanıyorsun") ve sen kısayolla sürdürene kadar bekler. Tek bir tıklama ya da fare sarsıntısı
  sayılmaz; birkaç kısa anda tekrarlanan girdi sayılır.
- **Tek sürücü.** Aynı anda yalnızca bir Claude oturumu ekranı sürebilir; ikincisi reddedilir.
- **Her an durdurabilirsin** (aşağıdaki kısayollar ya da menü).
- **Yalnızca elle çağrılır.** Claude bu skill'i kendi kararıyla başlatmaz; sen `/live-drive-desktop`
  yazarsın.

## Kurulum

Önce [Claude Code](https://docs.claude.com/en/docs/claude-code) kurulu olmalı (komut satırı ya da masaüstü
uygulaması).

```bash
git clone https://github.com/smlblr/live-drive-ai.git ~/live-drive-ai
```

```bash
~/live-drive-ai/install.sh
```

Repoyu istediğin yere klonlayabilirsin; kurulum skill'i oradan bağlar, o yüzden klasörü sonradan silme
ya da taşıma (taşırsan `install.sh`'yi yeni yerden yeniden çalıştır).

`install.sh` şunları yapar; iki kez çalıştırmak zararsızdır:

1. `skill/` klasörünü `~/.claude/skills/live-drive-desktop` olarak bağlar.
2. **macOS:** Xcode Command Line Tools'u denetler (yoksa `xcode-select --install`), bir kerelik
   kendinden imzalı kod imzalama sertifikası (`live-drive-codesign`) oluşturur, `LiveDrive.app`'i
   derleyip `~/Applications`'a koyar.
   **Linux:** gereken paketleri denetler, eksik varsa sorup `apt-get` ile kurar; durdur/duraklat
   kısayollarını GNOME'a ekler.
3. `~/.claude/settings.json`'a bir izin kuralı ekler; yoksa Claude her adımda onay ister. İstemiyorsan
   `./install.sh --no-settings`.
4. Son bir denetim yapar ve eksik kalanı söyler.

### macOS: iki izin

İlk kurulumun sonunda macOS'un kendi izin pencereleri çıkar ve LiveDrive iki listeye de eklenir:

- **Erişilebilirlik** (klavye ve fare)
- **Ekran ve Sistem Ses Kaydı** (ekran görüntüsü)

Her pencerede **Open System Settings**'e (Sistem Ayarları'nı Aç) bas, listede LiveDrive'ın anahtarını
aç, sonra terminalde Enter'a bas. `install.sh` yeniden denetler; hâlâ eksik olan varsa o ayar bölmesini
kendisi açar. Sonunda denetim `all granted` demeli; demiyorsa `./install.sh`'yi yeniden çalıştır. İlk testte macOS bir kez daha
"LiveDrive is requesting to bypass the system private window picker" diye sorabilir: **Allow**. İlk
oturumda bildirim izni de istenir (duraklatma uyarıları için).

İzinler imza sertifikasına bağlıdır: güncellemelerde yeniden derleme izinleri düşürmez. Sertifikayı
silersen ya da başka bir makineye geçersen iki izni yeniden verirsin.

### Linux: gerekenler

GNOME Wayland oturumu (giriş ekranında "Ubuntu on Xorg" değil). Ubuntu paket adlarıyla:
`python3-gi gir1.2-gstreamer-1.0 gir1.2-atspi-2.0 gstreamer1.0-pipewire gstreamer1.0-plugins-good`.
Çoğu Ubuntu masaüstünde zaten kuruludur. Debian tabanlı olmayan dağıtımlarda `install.sh` paketleri
kurmaz, karşılıklarını elle kur.

Üst çubuktaki LiveDrive simgesi için AppIndicator desteği gerekir (Ubuntu'da hazır gelen
`ubuntu-appindicators` eklentisi; başka dağıtımlarda "AppIndicator and KStatusNotifierItem Support"
eklentisi). Simge olmadan da test çalışır; durdurmak için kısayol yeter.

## Kullanım

Test edeceğin projenin klasöründe Claude Code'u aç ve yaz:

```
/live-drive-desktop ayarlar ekranında koyu temaya geçişi test et
```

İsteğe bağlı parametreler: `out=DİZİN` (ekran görüntülerinin yeri; proje bir yer tanımlamıyorsa Claude
sorar), `width=45%` (test penceresinin genişliği), `margin=20` (sağ kenardan boşluk, piksel).

Claude başlamadan önce ne test edeceğini, kaç adım süreceğini ve hangi pencereleri açacağını söyler.
Sonra test penceresini ekranın sağına yerleştirir, adımları kısa batch'ler hâlinde gönderir ve arada
ilerlemeyi yazar. Bitince "test bitti" der, ekran görüntülerinin yerini ve neyin geçip neyin kaldığını
raporlar, açtığı pencereleri kapatır.

### Durdurmak ve duraklatmak

| | macOS | Linux |
|---|---|---|
| Durdur | ⌃⌥⇧S ya da menü çubuğu → LiveDrive → Durdur | Ctrl+Alt+Shift+S, üst çubuk menüsü → Durdur ya da turuncu göstergedeki ■ |
| Duraklat / sürdür | ⌃⌥⇧P ya da menü → Duraklat/Sürdür | Ctrl+Alt+Shift+P ya da üst çubuk menüsü |

Menüdeki yazı durumu gösterir: **Sürüyor** (Claude şu an girdi gönderiyor), **Bekliyor** (batch'ler
arası; dokunman bir şeyi durdurmaz), **Duraklatıldı** ya da **Sen kullanıyorsun** (⏸, sürdürmeni
bekliyor). Test başlarken sen makineyi kullanıyorsan **Onayını bekliyor** olur, "Claude ekranı sürmek
istiyor" bildirimi çıkar ve menüdeki Başlat'ı ya da sürdür kısayolunu bekler.

### Seni nasıl fark eder

Test açıkken saniyede 10 kez (her 0,1 sn'de) son klavye/fare girdisine bakılır; yalnızca adımların
önünde değil, batch'ler arasında ve bekleme adımlarında da. Claude'un kendi gönderdiği girdi ayrılır:
Linux'ta Claude'un son girdisinden daha yeni olan girdi senindir, macOS'ta her olay hangi süreçten
geldiğini taşır.

Zaman 0,1 sn'lik dilimlere bölünür; aynı dilime düşen girdiler tek sayılır. Son 2 saniyede girdin
**en az 3 farklı dilime** düştüyse makineyi kullanıyorsun demektir:

| Ne yaptın | Kaç dilim | Sonuç |
|---|---|---|
| Fareye çarptın, fare sarsıldı (~40 ms) | 1–2 | sayılmaz |
| Tek tıklama (bas–bırak, ~0,1 sn) | 1–2 | sayılmaz |
| Fareyi bir yere götürdün, birkaç harf yazdın, tekerle kaydırdın | 3+ | duraklar |

Tek kısa tıklama testi durdurmaz; tıklama odağı başka bir pencereye götürdüyse odak kapısı bir sonraki
girdiyi yine durdurur. Yanlış duraksa `~/.cache/live-drive.out` içindeki
`user input: N events over X s, last Y s ago` satırı neyin durdurduğunu gösterir.

## Güncelleme

```bash
cd ~/live-drive-ai && git pull && ./install.sh
```

## Kaldırma

```bash
~/live-drive-ai/uninstall.sh
```

Skill bağını, `LiveDrive.app`'i, izin kuralını ve Linux'ta eklenen kısayolları kaldırır. İmza
sertifikasını silmez; silme komutunu sonda yazar. Repo klasörünü sonra kendin silebilirsin.

## Bilinen sınırlar ve riskler

- **Yönetilen (MDM) cihazlar.** Cihazın bir kurum tarafından yönetiliyorsa (Intune, Jamf, Kandji
  vb.) gizlilik politikası Erişilebilirlik ya da Ekran Kaydı iznini engelleyebilir, ya da bu izinleri
  yalnızca yöneticinin verebileceği şekilde kilitleyebilir. Bu durumda LiveDrive o cihazda çalışmaz.
  Denetlemek için:

  ```bash
  plutil -p "/Library/Managed Preferences/com.apple.TCC.configuration-profile-policy.plist"
  ```

  `Accessibility` ya da `ScreenCapture` altında `"Allowed" => 0` görüyorsan politika engelliyor.
  Dosya yoksa ya da bu servisler listede yoksa politika karışmıyor. Ayrıca yönetici olmayan bir hesap
  Gizlilik ayarlarında izni açamayabilir.
- **Kurum güvenlik araçları** (EDR, uç nokta koruması) sentetik klavye/fare girdisi üreten ya da ekran
  kaydeden, Apple tarafından onaylanmamış (kendinden imzalı) bir uygulamayı işaretleyebilir. Yönetilen bir cihaza kurmadan önce gerekiyorsa
  yöneticine sor.
- **Açıkken yerel yetki.** Test oturumu açıkken, senin kullanıcı hesabında çalışan herhangi bir süreç
  oturumun komut kanalına yazıp girdi gönderebilir. Kanal yalnızca senin hesabına açık, yalnızca test
  süresince var ve odak kapısı girdiyi test penceresiyle sınırlar; yine de güvenmediğin yazılım
  çalışırken test başlatma.
- **macOS:** yalnızca ana ekran. Metin olarak gönderildiği için her karakter (ğüşıöç, emoji) yazılır;
  tuş kodlarını okuyan uygulamalar farklı görebilir. Metin düzenleyiciler cümle başını büyük harfe
  çevirebilir ya da sistem metin değiştirmelerini uygulayabilir.
- **Linux:** yalnızca birincil monitör; kesirli ölçeklemede koordinatlar sapabilir. Etkin klavye
  düzeninde olmayan karakter (ör. 漢) hata vermeden düşer. Yazma sırasında aniden öne gelen bir pencere
  bir iki karakter alabilir; Claude uzun metni kısa parçalara böler.
- Yalnızca Claude Code ile denendi.

## Sorun giderme

Önce denetimi çalıştır; her eksik satır neyin eksik olduğunu ve nasıl düzeltileceğini söyler:

```bash
/usr/bin/python3 -I ~/.claude/skills/live-drive-desktop/scripts/live-drive.py check
```

- **"another session is driving the screen"** — başka bir Claude oturumu ekranı sürüyor. O oturumun
  testi bitince yeniden dene.
- **"live-drive.stop exists"** — oturum yokken durdur kısayoluna basılmış. `rm ~/.cache/live-drive.stop`
- **macOS'ta izin verdim ama hâlâ eksik görünüyor** — LiveDrive'ı listeden kaldırıp (−) yeniden
  `./install.sh` çalıştır, istemde yeniden aç.
- **LiveDrive Ekran Kaydı listesinde görünmüyorsa** — Sistem Ayarları'nı kapatıp `./install.sh`'yi
  yeniden çalıştır; liste açıkken eklenen kayıt bölme yeniden açılana kadar görünmeyebilir. Daha önce
  aynı yolda başka bir paket kimliğiyle kurulmuş bir LiveDrive varsa oturumu kapatıp aç.
- **İlk derlemede anahtar zinciri erişimi sorulursa** "Her Zaman İzin Ver" seç.

Neden böyle yapıldığı ve ölçümler: [`docs/decisions.md`](docs/decisions.md).

## Lisans

[MIT](LICENSE)
