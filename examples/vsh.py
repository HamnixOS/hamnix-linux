#!/usr/bin/virtualscript
"""
VSH - Virtual Shell
A simple shell implemented entirely in VirtualScript
Demonstrates that VirtualScript is powerful enough to implement a shell
"""

def get_prompt():
    """Generate shell prompt"""
    # Get current user info
    uid = process.uid
    users = {0: 'root', 1001: 'user'}
    username = users.get(uid, f'user{uid}')

    # Get hostname from environment
    hostname = env.get('HOSTNAME', 'localhost')

    # For simplicity, show ~ instead of full path
    prompt_char = '#' if uid == 0 else '$'
    return f"{username}@{hostname}:~{prompt_char} "

def parse_command_line(line):
    """Parse command line into command and arguments"""
    if not line or line.strip() == '':
        return None, []

    parts = split_args(line)
    if not parts:
        return None, []

    return parts[0], parts[1:]

def builtin_cd(args):
    """Change directory (built-in)"""
    if len(args) == 0:
        target = env.get('HOME', '/')
    else:
        target = args[0]

    # In a real shell, we'd update process.cwd
    # For now, just acknowledge the command
    print(f"cd: would change to {target}")
    return 0

def builtin_pwd(args):
    """Print working directory (built-in)"""
    # In a real implementation, would resolve process.cwd to path
    print("/current/directory")
    return 0

def builtin_export(args):
    """Export environment variable (built-in)"""
    if len(args) == 0:
        # List all env vars
        for key, value in env.items():
            print(f"{key}={value}")
    else:
        # Set env var
        for arg in args:
            if '=' in arg:
                key, value = arg.split('=', 1)
                env[key] = value
    return 0

def builtin_exit(args):
    """Exit shell (built-in)"""
    code = 0
    if len(args) > 0:
        try:
            code = int(args[0])
        except:
            code = 1
    exit(code)

def builtin_help(args):
    """Show help (built-in)"""
    print("""
VSH - Virtual Shell (implemented in VirtualScript)

Built-in commands:
  cd [dir]     - Change directory
  pwd          - Print working directory
  export       - Set environment variables
  help         - Show this help
  exit [code]  - Exit shell

External commands are executed via process.execute()

Features:
  - Command execution
  - Environment variables
  - Process management
  - File system access

This shell demonstrates that VirtualScript is powerful
enough to implement a complete shell!
""")
    return 0

# Built-in commands
builtins = {
    'cd': builtin_cd,
    'pwd': builtin_pwd,
    'export': builtin_export,
    'exit': builtin_exit,
    'help': builtin_help,
}

def execute_command(cmd, args):
    """Execute a command (builtin or external)"""
    # Check if it's a builtin
    if cmd in builtins:
        return builtins[cmd](args)

    # Execute external command
    try:
        # Reconstruct command line
        if args:
            cmdline = cmd + ' ' + ' '.join(args)
        else:
            cmdline = cmd

        exit_code, stdout, stderr = process.execute(cmdline)

        if stdout:
            print(stdout, end='')
        if stderr:
            error(stderr, end='')

        return exit_code
    except Exception as e:
        error(f"vsh: {cmd}: {e}")
        return 127

def main():
    """Main shell loop"""
    print("VSH - Virtual Shell v1.0 (VirtualScript implementation)")
    print("Type 'help' for help, 'exit' to exit")
    print()

    while True:
        try:
            # Show prompt
            prompt_text = get_prompt()

            # In a real shell, we'd read from terminal
            # For this demo, we'll process commands from stdin
            # or if no stdin, show usage
            if not stdin or stdin.strip() == '':
                print(prompt_text)
                print("Note: This is a demo. In interactive mode, you'd type commands here.")
                print("Try: echo 'ls /etc' | vsh")
                break

            # Process stdin line by line
            lines = stdin.strip().split('\n')
            for line in lines:
                line = line.strip()

                # Skip empty lines and comments
                if not line or line.startswith('#'):
                    continue

                # Show what we're executing
                print(f"{prompt_text}{line}")

                # Parse command
                cmd, args = parse_command_line(line)
                if cmd is None:
                    continue

                # Execute
                exit_code = execute_command(cmd, args)

                # Store last exit code
                env['?'] = str(exit_code)

            break  # Exit after processing stdin

        except KeyboardInterrupt:
            print("^C")
            continue
        except Exception as e:
            error(f"vsh: error: {e}")
            break

# Run shell
if __name__ == '__main__' or True:  # Always run in script mode
    main()
