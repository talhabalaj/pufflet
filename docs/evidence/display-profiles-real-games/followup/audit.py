"""Read-only exact Dev-prefix process audit. Never prints argv or other env values."""
import ctypes, json, pathlib, re, struct, subprocess
libc = ctypes.CDLL(None, use_errno=True)
prefix = pathlib.Path.home()/'Library/Application Support/PuffletDev/prefix'
def environment(pid):
    mib = (ctypes.c_int*3)(1, 49, pid)  # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t()
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0): return []
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0): return []
    data = buf.raw[:size.value]
    argc = struct.unpack_from('i',data)[0]
    end = data.find(b'\0',4)+1
    while end<len(data) and data[end]==0: end+=1
    for _ in range(argc):
        end = data.find(b'\0',end)+1
        if not end: return []
    return data[end:].split(b'\0')
clients=[]
for value in subprocess.check_output(['ps','-axo','pid='],text=True).split():
    pid=int(value)
    if ('WINEPREFIX='+str(prefix)).encode() not in environment(pid): continue
    name=subprocess.run(['ps','-p',value,'-o','comm='],text=True,capture_output=True).stdout.strip()
    clients.append({'pid':pid,'executable':re.sub(r'library-[a-f0-9]+','library-REDACTED',name.replace(str(pathlib.Path.home()),'~'))})
apps=[]
for line in subprocess.check_output(['ps','-axo','pid=,comm='],text=True).splitlines():
    if '/pufflet-real-games-build/' in line:
        pid,name=line.strip().split(None,1);apps.append({'pid':int(pid),'executable':name})
print(json.dumps({'dev_prefix_clients':clients,'test_build_processes':apps},indent=2))
