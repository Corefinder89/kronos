from subprocess import Popen


processes = []

for counter in range(10):
    chrome_cmd = 'export BROWSER=chrome && python3 python_scripts/script1.py'
    processes.append(Popen(chrome_cmd, shell=True))

for counter in range(5):
    processes[counter].wait()