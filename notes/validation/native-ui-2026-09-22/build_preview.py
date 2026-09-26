from pathlib import Path
import plistlib, shlex, subprocess, shutil
root=Path(__file__).resolve().parents[3]
out=Path(__file__).resolve().parent
bundle=Path('/tmp/Thongpari Native UI.app')
resources=Path('/tmp/thongpari-native-ui-preview')
resources.mkdir(exist_ok=True)
shutil.copytree(root/"data",resources/"data",dirs_exist_ok=True)
shutil.copy2(root/"LIF.metal",resources/"LIF.metal")
exe=bundle/'Contents/MacOS'; exe.mkdir(parents=True,exist_ok=True)
shutil.rmtree(exe/'data',ignore_errors=True)
(exe/'LIF.metal').unlink(missing_ok=True)

main=(root/'main.swift').read_text().replace('CommandLine.arguments.contains("--flygym")','true').replace('app.setActivationPolicy(.accessory)','app.setActivationPolicy(.regular)')
# Development preview uses exactly the production controllers and controls.
main=main.replace('let args = CommandLine.arguments','FileManager.default.changeCurrentDirectoryPath('+'"'+str(resources)+'"'+')\nlet args = CommandLine.arguments')
(out/'main.swift').write_text(main)
cmd=(root/'build.sh').read_text().split('swiftc ',1)[1].split(' || exit',1)[0]
argv=['swiftc']+shlex.split(cmd.replace('\\\n',' '));argv[argv.index('main.swift')]=str(out/'main.swift');argv[argv.index('-o')+1]=str(exe/'Lab')
subprocess.run(argv,cwd=root,check=True)
(bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.thongpari.native-ui','CFBundleName':'Thongpari Native UI','CFBundleExecutable':'Lab','CFBundlePackageType':'APPL','NSHighResolutionCapable':True}))
subprocess.run(['codesign','--force','--sign','-',str(bundle)],check=True)
