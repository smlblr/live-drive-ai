#!/usr/bin/python3 -I
"""Drive the live GNOME session through one Mutter RemoteDesktop + ScreenCast session.

  live-drive.py serve OUT_DIR      keep one session open (the top-bar indicator stays up)
  live-drive.py send STEP...       run steps in the serving session, print each as it ends
  live-drive.py quit               end the session
  live-drive.py check              report what the session needs, before starting one

Steps: focus:PID[,PID...]|any  key:alt+v  down:alt  up:alt  type:text  sleep:0.5  shot:name
       move:x,y  click[:right|middle]  dclick  scroll:down[,N]  drag:x1,y1,x2,y2

Focus gate: input steps run only while the active window (AT-SPI) belongs to a process set
with focus: (or one of its children); otherwise the batch stops with the window it found.
type: and drag look again every 0.2 s while they run. focus:any turns off the test-app
match, for apps that expose no accessibility tree; the chat window is refused even then.
type: understands \\n (Return), \\t (Tab) and \\\\ (backslash); Mutter silently drops a
character the active keyboard layout cannot produce.
key: takes X keysym names (F5, Delete, Menu, Print) besides the short ones (ctrl, pgdn).

Stop:  the ■ of the top-bar remote-access indicator, or touch ~/.cache/live-drive.stop
       (Ctrl+Alt+Shift+S). serve refuses to start while that file exists; it is removed on exit.
Pause: touch ~/.cache/live-drive.pause (Ctrl+Alt+Shift+P toggles it; remove it to resume)
       A notice stays on screen while paused; stop and resume show a short one.
Held keys and buttons are released on every exit.
Progress goes to ~/.cache/live-drive.out; shot:NAME logs the frame size, which is also the
coordinate space of move/drag.
"""
import json, os, signal, struct, sys, time

CACHE = os.path.expanduser('~/.cache')
FIFO = os.path.join(CACHE, 'live-drive.fifo')
OUT = os.path.join(CACHE, 'live-drive.out')
STOP = os.path.join(CACHE, 'live-drive.stop')
PAUSE = os.path.join(CACHE, 'live-drive.pause')
LOCK = os.path.join(CACHE, 'live-drive.lock')


def parent_of(pid):
    try:
        with open(f'/proc/{pid}/stat') as f:
            return int(f.read().rsplit(')', 1)[1].split()[1])
    except (ValueError, IndexError):
        return 0
    except OSError:                       # macOS: no /proc
        import subprocess
        try:
            return int(subprocess.check_output(['ps', '-o', 'ppid=', '-p', str(pid)]))
        except (subprocess.CalledProcessError, ValueError, OSError):
            return 0


def comm_of(pid):
    try:
        with open(f'/proc/{pid}/comm') as f:
            return f.read().strip()
    except OSError:
        import subprocess
        try:
            return os.path.basename(subprocess.check_output(['ps', '-o', 'comm=', '-p', str(pid)],
                                                            text=True).strip())
        except (subprocess.CalledProcessError, OSError):
            return ''


def session_owner():
    # The Claude session is the nearest `claude` process above us: every Bash call of one
    # session runs under it, another session has its own. Outside Claude (a terminal),
    # the shell's session id stands in.
    pid = parent_of(os.getpid())
    for _ in range(64):
        if pid <= 1:
            break
        if comm_of(pid) == 'claude':
            return f'claude:{pid}'
        pid = parent_of(pid)
    return f'sid:{os.getsid(0)}'


def take_lock():
    # One driver at a time (2026-11-02): a second serve used to replace the FIFO under the
    # first, so both read the same requests and one session's keys could pass the other's
    # focus gate. The lock lives as long as this process; the kernel frees it on any exit.
    import fcntl
    os.makedirs(CACHE, exist_ok=True)
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit(f'another session is driving the screen ({driver_text()}); '
                 'tell the user and try again when it has ended')
    os.ftruncate(fd, 0)
    os.write(fd, json.dumps({'serve': os.getpid(), 'owner': session_owner(),
                             'since': time.strftime('%H:%M:%S')}).encode())
    return fd


def driver():
    """Who holds the lock: its record, or None when no serve is running."""
    import fcntl
    try:
        fd = os.open(LOCK, os.O_RDONLY)
    except OSError:
        return None
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        return None
    except BlockingIOError:
        for _ in range(10):               # the holder may still be writing its record
            try:
                with open(LOCK) as f:
                    return json.load(f)
            except ValueError:
                time.sleep(0.1)
        return {}
    finally:
        os.close(fd)


def driver_text(d=None):
    d = driver() if d is None else d
    return f"serve pid {d.get('serve', '?')}, session {d.get('owner', '?')}, since {d.get('since', '?')}"


def send(steps):
    batch = str(time.time_ns())
    d = driver()
    if d is None:
        sys.exit('no serving session')
    if d.get('owner') != session_owner():
        sys.exit(f'another session is driving the screen ({driver_text(d)}); '
                 'this session cannot send to it: tell the user')
    try:
        fd = os.open(FIFO, os.O_WRONLY | os.O_NONBLOCK)
    except OSError:
        sys.exit('no serving session')
    start = os.path.getsize(OUT) if os.path.exists(OUT) else 0
    os.write(fd, (json.dumps({'id': batch, 'steps': steps}) + '\n').encode())
    os.close(fd)
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        with open(OUT) as f:
            f.seek(start)
            text = f.read()
        for line in text.splitlines():
            if line.startswith(f'END {batch} '):
                print(text.rstrip())
                sys.exit(0 if line.endswith(' ok') else 1)
        if not os.path.exists(FIFO):
            print(text.rstrip())
            sys.exit('session ended')
        time.sleep(0.1)
    with open(OUT) as f:
        f.seek(start)
        print(f.read().rstrip())
    if os.path.exists(PAUSE):
        # The batch is not lost: it runs when the user resumes. A resend would run it twice.
        resume = '⌃⌥⇧P' if sys.platform == 'darwin' else 'Ctrl+Alt+Shift+P'
        sys.exit(f'batch {batch} is waiting: the session is paused for the user ({resume} '
                 f'resumes it). Do not resend; tell the user, then watch {OUT} for "END {batch}"')
    sys.exit('timed out waiting for the batch')


def darwin(args):
    # macOS: the Swift helper does the driving (docs/decisions.md, live-drive-desktop). It
    # starts through `open` so TCC charges its grants to it, not to this chat; then launchd is
    # its parent, so the chat's processes go in --deny and this one in --parent.
    import subprocess
    app = os.path.expanduser('~/Applications/LiveDrive.app')
    if not os.path.isdir(app):
        sys.exit(f'{app} missing: run install.sh in the live-drive-ai checkout')
    if args == ['check']:
        helper = ['check']
    elif len(args) == 2 and args[0] == 'serve':
        if os.path.exists(STOP):
            sys.exit(f'{STOP} exists: a stop was requested; remove it to start a new session')
        global lock_fd
        lock_fd = take_lock()             # held while `open -W` waits for the helper
        chain, pid = [], os.getpid()
        while pid > 1 and len(chain) < 64:
            chain.append(pid)
            try:
                pid = int(subprocess.check_output(['ps', '-o', 'ppid=', '-p', str(pid)]))
            except (subprocess.CalledProcessError, ValueError):
                break
        helper = ['serve', os.path.abspath(args[1]), '--deny', ','.join(map(str, chain)),
                  '--parent', str(os.getpid()), '--owner', session_owner()]
    else:
        sys.exit(__doc__ + '\nmacOS: live-drive.py check  reports and requests LiveDrive.app permissions')
    os.makedirs(CACHE, exist_ok=True)
    # One file per call: a check run while a serve was open overwrote the shared one, and the
    # serve then exited with the check's output as its error (2026-11-02).
    err = os.path.join(CACHE, f'live-drive.{os.getpid()}.err')
    open(err, 'w').close()
    start = os.path.getsize(OUT) if os.path.exists(OUT) else 0
    # `open` returns 0 whatever the app did, so the helper's own output is the result.
    proc = subprocess.Popen(['open', '-W', '-n', '-g', '-a', app, '--stdout', err, '--stderr', err,
                             '--args'] + helper, stderr=subprocess.PIPE, text=True)
    if helper[0] == 'serve':
        # As on Linux, serve's own output names the owner: live-drive.out is shared.
        ready = f'READY {session_owner()} serve {os.getpid()}'
        while proc.poll() is None:
            with open(OUT) as f:
                f.seek(start)
                if ready in f.read().splitlines():
                    print(ready, flush=True)
                    break
            time.sleep(0.1)
    _, stderr = proc.communicate()
    # check exits before `open -W` finds its pid; that complaint is noise, anything else is not.
    for line in stderr.splitlines():
        if not line.startswith('Unable to block on application'):
            print(line, file=sys.stderr)
    with open(err) as f:
        text = f.read().rstrip()
    os.remove(err)
    if text:
        print(text)
    if helper == ['check']:
        # What the helper cannot see: another session's lock and a stop left behind.
        d = driver()
        busy = d is not None and d.get('owner') != session_owner()
        if busy:
            print(f'MISS  no other session driving the screen: {driver_text(d)} holds it; wait for it to end')
        if os.path.exists(STOP):
            print(f'MISS  no pending stop: {STOP} exists; serve refuses to start (the user removes it)')
        sys.exit(0 if text.endswith('all granted') and not busy and not os.path.exists(STOP) else 1)
    sys.exit(0 if not text else 1)


if len(sys.argv) >= 2 and sys.argv[1] in ('send', 'quit'):
    send(sys.argv[2:] if sys.argv[1] == 'send' else ['quit'])

def linux_check():
    # Same role as LiveDrive.app check: find what is missing before the first input, not
    # halfway through a test. Prints one line per item and returns the exit code.
    problems = []

    def item(ok, name, fix='', warn=False):
        print(('ok    ' if ok else 'warn  ' if warn else 'MISS  ') + name + ('' if ok else f': {fix}'))
        if not ok and not warn:
            problems.append(name)

    item(os.environ.get('XDG_SESSION_TYPE') == 'wayland'
         and 'GNOME' in os.environ.get('XDG_CURRENT_DESKTOP', ''),
         'GNOME Wayland session', 'KDE and X11 are not supported')
    try:
        import ctypes
        import gi
        gi.require_version('Gst', '1.0')
        gi.require_version('Atspi', '2.0')
        from gi.repository import Atspi, Gio, GLib, Gst
    except (ImportError, ValueError) as e:
        item(False, 'python3-gi with Gst and Atspi', f'{e} (gir1.2-gstreamer-1.0, gir1.2-atspi-2.0)')
        print(f'{len(problems)} problem(s)')
        return 1
    item(True, 'python3-gi with Gst and Atspi')
    Gst.init(None)
    missing = [e for e in ('pipewiresrc', 'videoconvert', 'pngenc') if not Gst.ElementFactory.find(e)]
    item(not missing, 'GStreamer elements', ' '.join(missing) + ' (gstreamer1.0-pipewire, gstreamer1.0-plugins-good)')
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)

    def owned(name):
        return bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                             'NameHasOwner', GLib.Variant('(s)', (name,)), None, 0, 5000, None).unpack()[0]
    item(owned('org.gnome.Mutter.RemoteDesktop'), 'Mutter RemoteDesktop on D-Bus', 'not GNOME Shell?')
    item(owned('org.freedesktop.Notifications'), 'notifications (pause/stop notices)',
         'pause and stop will work without a notice', warn=True)
    item(owned('org.kde.StatusNotifierWatcher'), 'top-bar icon (Durdur/Duraklat menu)',
         'no StatusNotifierWatcher; enable the ubuntu-appindicators extension', warn=True)
    desk = Atspi.get_desktop(0)
    item(desk is not None and desk.get_child_count() > 0, 'AT-SPI sees applications',
         'the focus gate cannot work; is accessibility (at-spi2-core) running?')
    try:
        xkb = ctypes.CDLL('libxkbcommon.so.0')
        xkb.xkb_utf32_to_keysym.restype = ctypes.c_uint32
        item(xkb.xkb_utf32_to_keysym(0x11f) == 0x2bb, 'libxkbcommon', 'unexpected keysym for ğ')
    except OSError as e:
        item(False, 'libxkbcommon', str(e))
    try:
        import subprocess
        keys = 'org.gnome.settings-daemon.plugins.media-keys'
        out = subprocess.run(['gsettings', 'get', keys, 'custom-keybindings'],
                             capture_output=True, text=True).stdout
        cmds = ''
        for path in out.strip("[]@as \n").replace("'", '').split(', '):
            if path:
                cmds += subprocess.run(['gsettings', 'get', f'{keys}.custom-keybinding:{path}', 'command'],
                                       capture_output=True, text=True).stdout
        item('live-drive.stop' in cmds and 'live-drive.pause' in cmds, 'stop/pause shortcuts',
             'Ctrl+Alt+Shift+S/P are not set; run install.sh in the live-drive-ai checkout', warn=True)
    except OSError as e:
        item(False, 'stop/pause shortcuts', str(e), warn=True)
    d = driver()
    item(d is None or d.get('owner') == session_owner(), 'no other session driving the screen',
         f'{driver_text(d)} holds it; wait for it to end' if d is not None else '')
    item(not os.path.exists(STOP), 'no pending stop', f'{STOP} exists; serve refuses to start (the user removes it)')
    item(not os.path.exists(PAUSE), 'not paused', f'{PAUSE} exists; sends will wait', warn=True)
    print('all ok' if not problems else f'{len(problems)} problem(s)')
    return 1 if problems else 0


if sys.platform == 'darwin':
    darwin(sys.argv[1:])
if sys.argv[1:] == ['check']:
    sys.exit(linux_check())

if len(sys.argv) != 3 or sys.argv[1] != 'serve':
    sys.exit(__doc__)
if os.path.exists(STOP):
    sys.exit(f'{STOP} exists: a stop was requested; remove it to start a new session')
lock_fd = take_lock()

import ctypes
import gi
gi.require_version('Gst', '1.0')
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, Gio, GLib, Gst

KEYSYMS = {
    'alt': 0xffe9, 'shift': 0xffe1, 'ctrl': 0xffe3, 'super': 0xffeb,
    'return': 0xff0d, 'up': 0xff52, 'down': 0xff54, 'left': 0xff51, 'right': 0xff53,
    'escape': 0xff1b, 'backspace': 0xff08, 'insert': 0xff63, 'tab': 0xff09,
    'space': 0x20, 'home': 0xff50, 'end': 0xff57, 'pgdn': 0xff56, 'pgup': 0xff55,
    'delete': 0xffff, 'menu': 0xff67,
}
_xkb = ctypes.CDLL('libxkbcommon.so.0')
_xkb.xkb_keysym_from_name.restype = ctypes.c_uint32
_xkb.xkb_utf32_to_keysym.restype = ctypes.c_uint32
BUTTONS = {'': 0x110, 'left': 0x110, 'right': 0x111, 'middle': 0x112}
SCROLL = {'down': (0, 1), 'up': (0, -1), 'right': (1, 1), 'left': (1, -1)}
RD = 'org.gnome.Mutter.RemoteDesktop'
SC = 'org.gnome.Mutter.ScreenCast'
bus = Gio.bus_get_sync(Gio.BusType.SESSION)


def call(dest, path, iface, method, params=None, reply=None):
    return bus.call_sync(dest, path, iface, method, params,
                         GLib.VariantType(reply) if reply else None,
                         Gio.DBusCallFlags.NONE, 5000, None)


out_dir = sys.argv[2]
os.makedirs(out_dir, exist_ok=True)
rd_path = call(RD, '/org/gnome/Mutter/RemoteDesktop', RD, 'CreateSession', None, '(o)').unpack()[0]
rd_id = bus.call_sync(RD, rd_path, 'org.freedesktop.DBus.Properties', 'Get',
                      GLib.Variant('(ss)', (RD + '.Session', 'SessionId')),
                      GLib.VariantType('(v)'), 0, 5000, None).unpack()[0]
sc_path = call(SC, '/org/gnome/Mutter/ScreenCast', SC, 'CreateSession',
               GLib.Variant('(a{sv})', ({'remote-desktop-session-id': GLib.Variant('s', rd_id)},)),
               '(o)').unpack()[0]
stream_path = call(SC, sc_path, SC + '.Session', 'RecordMonitor',
                   GLib.Variant('(sa{sv})', ('', {'cursor-mode': GLib.Variant('u', 1)})),
                   '(o)').unpack()[0]
state = {'node': None, 'closed': False}


def on_stream(_c, _s, _p, _i, _n, params):
    state['node'] = params.unpack()[0]


def on_closed(*_a):
    state['closed'] = True


bus.signal_subscribe(SC, SC + '.Stream', 'PipeWireStreamAdded', stream_path, None, 0, on_stream)
bus.signal_subscribe(RD, RD + '.Session', 'Closed', rd_path, None, 0, on_closed)
call(RD, rd_path, RD + '.Session', 'Start')
ctx = GLib.MainContext.default()


def pump():
    while ctx.pending():
        ctx.iteration(False)


t0 = time.monotonic()
while state['node'] is None and time.monotonic() - t0 < 5:
    ctx.iteration(True)
if state['node'] is None:
    sys.exit('no PipeWire stream')
Gst.init(None)

held_keys, held_buttons = set(), set()


def log(line):
    with open(OUT, 'a') as f:
        f.write(line + '\n')


# ---- top-bar icon: macOS shows "● LiveDrive" in the menu bar. Here the same comes from
# StatusNotifierItem + DBusMenu, the protocols Ubuntu's ubuntu-appindicators and KDE read,
# spoken directly over Gio: libayatana-appindicator is deprecated and its GLib successor
# exports a menu format the GNOME extension does not read (docs/decisions.md, live-drive-desktop).
SNI_XML = """<node>
<interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="WindowId" type="i" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconThemePath" type="s" access="read"/>
  <property name="OverlayIconName" type="s" access="read"/>
  <property name="AttentionIconName" type="s" access="read"/>
  <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <property name="XAyatanaLabel" type="s" access="read"/>
  <property name="XAyatanaLabelGuide" type="s" access="read"/>
  <signal name="NewIcon"/>
  <signal name="NewToolTip"/>
  <signal name="NewStatus"><arg type="s"/></signal>
  <signal name="XAyatanaNewLabel"><arg type="s"/><arg type="s"/></signal>
</interface>
<interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/>
  <property name="TextDirection" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconThemePath" type="as" access="read"/>
  <method name="GetLayout">
    <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
  </method>
  <method name="GetGroupProperties">
    <arg type="ai" direction="in"/><arg type="as" direction="in"/>
    <arg type="a(ia{sv})" direction="out"/>
  </method>
  <method name="GetProperty">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
  </method>
  <method name="Event">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/>
    <arg type="u" direction="in"/>
  </method>
  <method name="EventGroup">
    <arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/>
  </method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <method name="AboutToShowGroup">
    <arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/>
  </method>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface>
</node>"""
SNI_PATH, MENU_PATH = '/StatusNotifierItem', '/StatusNotifierItem/Menu'
tray = {'state': None, 'busy': False, 'rev': 1, 'on': False}
# Why the session waits: tray status, tray button, notice title, notice body.
PAUSED = {
    'pause': ('Duraklatıldı', 'Sürdür', 'Test duraklatıldı', 'Sürdürmek için Ctrl+Alt+Shift+P'),
    'start': ('Onayını bekliyor', 'Başlat', 'Claude ekranı sürmek istiyor',
              'Ekranı kullanıyordun. Hazır olunca başlatmak için Ctrl+Alt+Shift+P'),
    'user': ('Sen kullanıyorsun', 'Sürdür', 'Sen kullanıyorsun, test duraklatıldı',
             'Hazır olunca sürdürmek için Ctrl+Alt+Shift+P'),
}


def tray_status():
    if tray['state']:
        return PAUSED[tray['state']][0]
    # An open session that sends nothing while Claude thinks looked like it was driving, so
    # the user took a missing pause for a missed one (2026-11-02). Touching it then is safe.
    return 'Sürüyor' if tray['busy'] else 'Bekliyor'


def tray_items():
    st = tray['state']
    return {
        0: {'children-display': GLib.Variant('s', 'submenu')},
        1: {'label': GLib.Variant('s', tray_status()),
            'enabled': GLib.Variant('b', False)},
        2: {'type': GLib.Variant('s', 'separator')},
        3: {'label': GLib.Variant('s', (PAUSED[st][1] if st else 'Duraklat') + '  (Ctrl+Alt+Shift+P)')},
        4: {'label': GLib.Variant('s', 'Durdur  (Ctrl+Alt+Shift+S)')},
    }


def tray_click(item):
    # Same files as the shortcuts, so gate() stays the one place that acts on them.
    if item == 3:
        if os.path.exists(PAUSE):
            os.remove(PAUSE)
        else:
            open(PAUSE, 'a').close()
    elif item == 4:
        open(STOP, 'a').close()


def tray_method(_c, _s, _p, _iface, method, params, inv):
    items = tray_items()
    args = params.unpack()
    if method == 'GetLayout':
        node = lambda i: (i, items[i], [GLib.Variant('(ia{sv}av)', node(c)) for c in
                                        ((1, 2, 3, 4) if i == 0 else ())])
        inv.return_value(GLib.Variant('(u(ia{sv}av))', (tray['rev'], node(args[0] if args[0] in items else 0))))
    elif method == 'GetGroupProperties':
        ids = args[0] or list(items)
        inv.return_value(GLib.Variant('(a(ia{sv}))', ([(i, items[i]) for i in ids if i in items],)))
    elif method == 'GetProperty':
        inv.return_value(GLib.Variant('(v)', (items.get(args[0], {}).get(args[1], GLib.Variant('s', '')),)))
    elif method == 'Event':
        if args[1] == 'clicked':
            tray_click(args[0])
        inv.return_value(None)
    elif method == 'EventGroup':
        for item, event, _d, _t in args[0]:
            if event == 'clicked':
                tray_click(item)
        inv.return_value(GLib.Variant('(ai)', ([],)))
    elif method == 'AboutToShow':
        inv.return_value(GLib.Variant('(b)', (False,)))
    elif method == 'AboutToShowGroup':
        inv.return_value(GLib.Variant('(aiai)', ([], [])))


def tray_property(_c, _s, _p, iface, name):
    # Yaru's user-idle is a half-transparent bubble that read as a faded icon (user, 2026-11-02).
    icon = ('media-playback-pause-symbolic' if tray['state'] else
            'media-record-symbolic' if tray['busy'] else 'preferences-system-time-symbolic')
    state = tray_status()
    if iface == 'com.canonical.dbusmenu':
        return {'Version': GLib.Variant('u', 3), 'TextDirection': GLib.Variant('s', 'ltr'),
                'Status': GLib.Variant('s', 'normal'), 'IconThemePath': GLib.Variant('as', [])}[name]
    return {'Category': GLib.Variant('s', 'ApplicationStatus'), 'Id': GLib.Variant('s', 'live-drive'),
            'Title': GLib.Variant('s', 'Live drive'), 'Status': GLib.Variant('s', 'Active'),
            'WindowId': GLib.Variant('i', 0), 'IconName': GLib.Variant('s', icon),
            'IconThemePath': GLib.Variant('s', ''), 'OverlayIconName': GLib.Variant('s', ''),
            'AttentionIconName': GLib.Variant('s', ''),
            'ToolTip': GLib.Variant('(sa(iiay)ss)', (icon, [], 'Live drive', state)),
            'ItemIsMenu': GLib.Variant('b', True), 'Menu': GLib.Variant('o', MENU_PATH),
            'XAyatanaLabel': GLib.Variant('s', tray_label()),
            'XAyatanaLabelGuide': GLib.Variant('s', tray_label())}[name]


def tray_label():
    return f'Live drive · {tray_status()}'


def tray_start():
    # Optional: without a StatusNotifierWatcher (no ubuntu-appindicators) there is no icon,
    # and the shortcuts and notices still work.
    try:
        info = Gio.DBusNodeInfo.new_for_xml(SNI_XML)
        # register_object is deprecated in PyGObject 3.56; closures2 is its replacement.
        register = getattr(bus, 'register_object_with_closures2', bus.register_object)
        for iface, path in ((info.interfaces[0], SNI_PATH), (info.interfaces[1], MENU_PATH)):
            register(path, iface, tray_method, tray_property, None)
        call('org.kde.StatusNotifierWatcher', '/StatusNotifierWatcher', 'org.kde.StatusNotifierWatcher',
             'RegisterStatusNotifierItem', GLib.Variant('(s)', (SNI_PATH,)))
        tray['on'] = True
    except GLib.Error as e:
        log(f'no top-bar icon: {e.message}')


def tray_set(**kw):
    if not tray['on'] or all(tray[k] == v for k, v in kw.items()):
        return
    tray.update(kw)
    tray['rev'] += 1
    for path, iface, sig, args in (
            (MENU_PATH, 'com.canonical.dbusmenu', 'LayoutUpdated', GLib.Variant('(ui)', (tray['rev'], 0))),
            (SNI_PATH, 'org.kde.StatusNotifierItem', 'NewIcon', None),
            (SNI_PATH, 'org.kde.StatusNotifierItem', 'NewToolTip', None),
            (SNI_PATH, 'org.kde.StatusNotifierItem', 'XAyatanaNewLabel',
             GLib.Variant('(ss)', (tray_label(), tray_label())))):
        bus.emit_signal(None, path, iface, sig, args)
    pump()


def tray_paused(st):
    tray_set(state=st)


tray_start()
NOTES = 'org.freedesktop.Notifications'
note = {'id': 0}


def notify(summary, body='', sticky=False, icon='media-playback-start-symbolic'):
    # The shortcuts gave no sign they were pressed (user, 2026-11-02). A critical notice stays
    # on screen until closed, so the paused state is visible for as long as it lasts.
    hints = {'urgency': GLib.Variant('y', 2 if sticky else 1),
             'transient': GLib.Variant('b', not sticky)}
    try:
        note['id'] = call(NOTES, '/org/freedesktop/Notifications', NOTES, 'Notify',
                          GLib.Variant('(susssasa{sv}i)', (
                              'Live drive', note['id'], icon, summary, body, [], hints,
                              0 if sticky else 2500)),
                          '(u)').unpack()[0]
    except GLib.Error:
        pass


def unnotify():
    try:
        call(NOTES, '/org/freedesktop/Notifications', NOTES, 'CloseNotification',
             GLib.Variant('(u)', (note['id'],)))
    except GLib.Error:
        pass


def stopped():
    if os.path.exists(STOP):
        notify('Test durduruldu', icon='media-playback-stop-symbolic')
    raise SystemExit('stopped by user')


IDLE = 'org.gnome.Mutter.IdleMonitor'
synthetic = {'last': time.monotonic(), 'grace': 0.0, 'sent': False}
pending = {'reason': None}
theirs = []                               # moments of input that was not ours, oldest first


def mark_input():
    synthetic['last'] = time.monotonic()
    synthetic['sent'] = True


def sample():
    # Our synthetic input resets Mutter's idle time too, before the D-Bus call returns
    # (measured, 2026-11-02), so input newer than our last event is theirs. Timing from before
    # the query keeps our own event at or before 'last' however slow the reply is.
    t = time.monotonic()
    try:
        idle = call(IDLE, '/org/gnome/Mutter/IdleMonitor/Core', IDLE, 'GetIdletime', None,
                    '(t)').unpack()[0] / 1000
    except GLib.Error:
        return
    moment = t - idle
    if moment > max(synthetic['last'], synthetic['grace']) + 0.005 and \
            (not theirs or moment - theirs[-1] > 0.005):
        theirs.append(moment)
    while theirs and t - theirs[0] > 2.0:
        theirs.pop(0)


def user_active():
    # Driving while the user types or moves the mouse fights them for the input (user,
    # 2026-11-02). A single burst (a bumped mouse, one click) paused live tests while nobody
    # was using the machine, so it takes input in 3 separate 0.1 s slices within 2 s.
    sample()
    return len({int(m * 10) for m in theirs}) >= 3


def yield_to_user():
    # The user asked for an explicit go-ahead rather than a wait for them to stop: the
    # session pauses and asks for Ctrl+Alt+Shift+P, like a pause they pressed themselves.
    if user_active():
        pending['reason'] = 'user' if synthetic['sent'] else 'start'
        log_theirs()
        open(PAUSE, 'a').close()
        gate()


def log_theirs():
    now = time.monotonic()
    log(f'user input: {len(theirs)} events over {theirs[-1] - theirs[0]:.2f} s, '
        f'last {now - theirs[-1]:.2f} s ago')


def gate():
    pump()
    sample()                              # every 0.1 s while idle or sleeping: input between our events
    if state['closed'] or os.path.exists(STOP):
        stopped()
    if not os.path.exists(PAUSE):
        return
    reason, pending['reason'] = pending['reason'] or 'pause', None
    log(f'paused ({reason})')
    release_all()                         # a held synthetic Shift would leak into their typing
    tray_paused(reason)
    _, _, title, body = PAUSED[reason]
    notify(title, body, sticky=True, icon='media-playback-pause-symbolic')
    while os.path.exists(PAUSE):
        time.sleep(0.3)
        pump()
        if state['closed'] or os.path.exists(STOP):
            unnotify()
            stopped()
    unnotify()
    tray_paused(None)
    notify('Test sürdürüldü')
    log('resumed')
    # Pressing the shortcut (or the menu) is input too; do not take it for the user again.
    synthetic['grace'] = time.monotonic() + 1.0
    theirs.clear()
    # The user may have clicked another window while paused; look again before input.
    focus_seen['t'] = 0.0


def keysym(down, sym):
    (held_keys.add if down else held_keys.discard)(sym)
    call(RD, rd_path, RD + '.Session', 'NotifyKeyboardKeysym', GLib.Variant('(ub)', (sym, down)))
    mark_input()


def button(down, btn=0x110):
    (held_buttons.add if down else held_buttons.discard)(btn)
    call(RD, rd_path, RD + '.Session', 'NotifyPointerButton', GLib.Variant('(ib)', (btn, down)))
    mark_input()


def move(x, y):
    call(RD, rd_path, RD + '.Session', 'NotifyPointerMotionAbsolute',
         GLib.Variant('(sdd)', (stream_path, x, y)))
    mark_input()


def char_sym(ch):
    # Mutter looks the keysym up in the active layout, which names ğ/ş/ı by their legacy
    # keysyms (gbreve 0x2bb); the Unicode form 0x100011f was dropped silently (2026-11-01).
    # xkb_utf32_to_keysym gives the legacy one where it exists; \n would map to Linefeed.
    if ch == '\n':
        return 0xff0d
    return _xkb.xkb_utf32_to_keysym(ord(ch)) or 0x01000000 + ord(ch)


def sym_of(k):
    if k in KEYSYMS:
        return KEYSYMS[k]
    if len(k) == 1:
        return char_sym(k)
    sym = _xkb.xkb_keysym_from_name(k.encode(), 1)   # 1 = case-insensitive (f5, page_down)
    if not sym:
        raise ValueError(f'unknown key {k}')
    return sym


def unescape(text):
    out, it = [], iter(text)
    for ch in it:
        if ch == '\\':
            nxt = next(it, '')
            out.append({'n': '\n', 't': '\t', '\\': '\\'}.get(nxt, '\\' + nxt))
        else:
            out.append(ch)
    return ''.join(out)


# ---- focus gate: on 2026-10-20 a batch typed `exit` + Return into the Claude chat
# because focus had moved; a screenshot rule did not prevent it, so the check is in code.
allowed = {'pids': None}          # None = focus: not given yet; set() never; 'any' = off


def ancestors(pid):
    seen = []
    while pid > 1 and len(seen) < 64:
        seen.append(pid)
        try:
            with open(f'/proc/{pid}/stat') as f:
                pid = int(f.read().rsplit(')', 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return seen


def active_windows():
    # A closed or hidden Chromium window can keep ACTIVE (2026-11-01: a Brave private window
    # beside the focused editor), so prefer windows that are also SHOWING and return them all.
    desk = Atspi.get_desktop(0)
    active, showing = [], []
    for i in range(desk.get_child_count()):
        app = desk.get_child_at_index(i)
        if app is None:
            continue
        for j in range(app.get_child_count()):
            win = app.get_child_at_index(j)
            if win is None:
                continue
            states = win.get_state_set()
            if states.contains(Atspi.StateType.ACTIVE):
                w = (app.get_process_id(), app.get_name(), win.get_name())
                active.append(w)
                if states.contains(Atspi.StateType.SHOWING):
                    showing.append(w)
    return showing or active


CHAT = set(ancestors(os.getpid()))     # serve's ancestors: the chat app and its launchers
focus_seen = {'t': 0.0}


def check_focus(when):
    if allowed['pids'] is None:
        raise RuntimeError('no focus: step yet; send focus:PID of the test window first (or focus:any)')
    acts = active_windows()
    # As on macOS, focus:any turns off only the test-app match, never the chat refusal.
    for pid, app, title in acts:
        if pid in CHAT:
            raise RuntimeError(f'focus is the chat ({app} pid {pid} "{title}") {when}; '
                               'bring the test window to the front')
    focus_seen['t'] = time.monotonic()
    if allowed['pids'] == 'any':
        return
    if not acts:
        raise RuntimeError(f'focus unknown {when}: no active window in AT-SPI; '
                           'verify with shot: and use focus:any if the app has no accessibility tree')
    # The window may belong to a child of the PID we started (launchers fork). Never the
    # other way round: the test app's ancestors include this chat's own process.
    # With several candidates every one must be allowed: we cannot tell which is real.
    for pid, app, title in acts:
        if not allowed['pids'] & set(ancestors(pid)):
            raise RuntimeError(f'focus is {app} pid {pid} "{title}" {when}, expected pid '
                               + ','.join(map(str, sorted(allowed['pids']))))


def recheck(when):
    # Mutter sends keys to whatever is in front; unlike macOS postToPid there is no way to
    # address the test process. A long type: or drag looks again every 0.2 s (one AT-SPI
    # query is ~56 ms), so a window that comes up mid-step gets at most a few characters.
    if time.monotonic() - focus_seen['t'] >= 0.2:
        check_focus(when)


def combo(spec):
    syms = [sym_of(k) for k in spec.lower().split('+')]
    for s in syms:
        keysym(True, s)
        time.sleep(0.03)
    for s in reversed(syms):
        keysym(False, s)
        time.sleep(0.03)


def shot(name):
    path = os.path.join(out_dir, name)
    pipe = Gst.parse_launch(
        f'pipewiresrc path={state["node"]} do-timestamp=true num-buffers=8 ! videoconvert ! '
        f'pngenc snapshot=false ! multifilesink location={path}.%d.png')
    pipe.set_state(Gst.State.PLAYING)
    pipe.get_bus().timed_pop_filtered(8 * Gst.SECOND, Gst.MessageType.EOS | Gst.MessageType.ERROR)
    pipe.set_state(Gst.State.NULL)
    frames = sorted((f for f in os.listdir(out_dir) if f.startswith(name + '.') and f.endswith('.png')
                     and f[len(name) + 1:-4].isdigit()), key=lambda f: int(f[len(name) + 1:-4]))
    if frames:
        os.replace(os.path.join(out_dir, frames[-1]), path + '.png')
        for f in frames[:-1]:
            os.remove(os.path.join(out_dir, f))
        with open(path + '.png', 'rb') as f:
            w, h = struct.unpack('>II', f.read(24)[16:24])
        log(f'shot {path}.png {w}x{h}')
    else:
        raise RuntimeError(f'no frame captured for {name}')


def sleep(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        gate()
        time.sleep(0.1)


INPUT = {'key', 'down', 'up', 'type', 'click', 'dclick', 'scroll', 'drag'}


def run(step):
    kind, _, arg = step.partition(':')
    if kind in INPUT or kind == 'move':
        yield_to_user()
    if kind in INPUT:
        check_focus(f'before {kind}')
    if kind == 'focus':
        pids = 'any' if arg == 'any' else {int(p) for p in arg.split(',')}
        # serve's own ancestors include the chat that started it; allowing one of them
        # would let input reach the chat again.
        if pids != 'any' and pids & CHAT:
            raise ValueError(f'focus:{arg} includes an ancestor of this session (the chat); '
                             'give the PID of the test app')
        allowed['pids'] = pids
        log(f'focus allowed={arg} active={active_windows()}')
    elif kind == 'key':
        combo(arg)
    elif kind == 'down':
        keysym(True, sym_of(arg))
    elif kind == 'up':
        keysym(False, sym_of(arg))
    elif kind == 'type':
        for ch in unescape(arg):
            gate()
            yield_to_user()
            recheck('during type')
            keysym(True, char_sym(ch))
            keysym(False, char_sym(ch))
            time.sleep(0.04)
    elif kind == 'sleep':
        sleep(float(arg))
    elif kind == 'shot':
        shot(arg)
    elif kind == 'move':
        move(*(float(v) for v in arg.split(',')))
    elif kind in ('click', 'dclick'):
        btn = BUTTONS[arg]
        for _ in range(2 if kind == 'dclick' else 1):
            button(True, btn)
            button(False, btn)
            time.sleep(0.08)
    elif kind == 'scroll':
        direction, _, n = arg.partition(',')
        axis, sign = SCROLL[direction]
        call(RD, rd_path, RD + '.Session', 'NotifyPointerAxisDiscrete',
             GLib.Variant('(ui)', (axis, sign * int(n or 1))))
        mark_input()
    elif kind == 'drag':
        x1, y1, x2, y2 = (float(v) for v in arg.split(','))
        move(x1, y1)
        time.sleep(0.1)
        button(True)
        for i in range(1, 21):
            gate()
            if user_active():
                # Pausing with the button held would drag wherever the user moves the mouse.
                pending['reason'] = 'user'
                log_theirs()
                open(PAUSE, 'a').close()
                raise RuntimeError('the user took the mouse during drag; button released, '
                                   'session paused; redo the drag after they resume')
            recheck('during drag')
            move(x1 + (x2 - x1) * i / 20, y1 + (y2 - y1) * i / 20)
            time.sleep(0.03)
        time.sleep(0.1)
        button(False)
    else:
        raise ValueError(f'unknown step {step}')
    time.sleep(0.05)
    # A click lands wherever the pointer is, which AT-SPI cannot see on Wayland; if it
    # focused another window, stop here instead of typing into it in the next step.
    if kind in ('click', 'dclick', 'drag'):
        time.sleep(0.15)
        check_focus(f'after {kind}')


def release_all():
    for s in list(held_keys):
        try:
            keysym(False, s)
        except Exception:
            pass
    for b in list(held_buttons):
        try:
            button(False, b)
        except Exception:
            pass


signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit('terminated')))
if os.path.exists(FIFO):
    os.remove(FIFO)
os.mkfifo(FIFO, 0o600)
# live-drive.out is shared by every session, and a refused serve leaves the last one's READY
# there; another session took that line for its own (2026-11-02). Name the owner, and say it
# on serve's own output too.
ready = f'READY {session_owner()} serve {os.getpid()}'
log(ready)
print(ready, flush=True)
try:
    while True:
        gate()
        fd = os.open(FIFO, os.O_RDONLY | os.O_NONBLOCK)
        buf = b''
        while not buf.endswith(b'\n'):
            gate()
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                chunk = b''
            if not chunk:
                time.sleep(0.1)
            buf += chunk
        os.close(fd)
        for line in buf.decode().splitlines():
            req = json.loads(line)
            if req['steps'] == ['quit']:
                log(f'END {req["id"]} ok')
                raise SystemExit(0)
            status = 'ok'
            tray_set(busy=True)
            try:
                for step in req['steps']:
                    gate()
                    run(step)
                    log(f'done {step}')
            except SystemExit as e:
                log(f'END {req["id"]} {e}')
                raise
            except Exception as e:
                status = f'error {e}'
                release_all()
            tray_set(busy=False)
            log(f'END {req["id"]} {status}')
finally:
    release_all()
    # A pause belongs to this session; left behind, the next one would start paused.
    for f in (FIFO, STOP, PAUSE):
        try:
            os.remove(f)
        except OSError:
            pass
    try:
        call(RD, rd_path, RD + '.Session', 'Stop')
    except Exception:
        pass
