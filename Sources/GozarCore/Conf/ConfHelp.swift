enum ConfHelp {
    static let legacy = [
        "bypass": """
        usage: bypass [-h] [--cisco] [--router]

        optional arguments:
          -h, --help  show this help message and exit
          --cisco
          --router
        """,
        "check": """
        usage: check [-h] [--cisco] [--json] site

        positional arguments:
          site

        optional arguments:
          -h, --help  show this help message and exit
          --cisco
          --json
        """,
        "routes": """
        usage: routes [-h] [--cisco] [--json]

        optional arguments:
          -h, --help  show this help message and exit
          --cisco
          --json
        """,
        "add-to": """
        usage: add-to [-h] name {vpn,cisco,direct} sites [sites ...]

        positional arguments:
          name
          {vpn,cisco,direct}
          sites

        optional arguments:
          -h, --help          show this help message and exit
        """,
        "rule-set": """
        usage: rule-set [-h] [--route {vpn,cisco,direct}]
                        [--without-cisco {direct,vpn,none}] [--enabled {true,false}]
                        [--rename RENAME] [--note NOTE]
                        name

        positional arguments:
          name

        optional arguments:
          -h, --help            show this help message and exit
          --route {vpn,cisco,direct}
          --without-cisco {direct,vpn,none}
          --enabled {true,false}
          --rename RENAME
          --note NOTE
        """,
        "rule-delete": """
        usage: rule-delete [-h] name

        positional arguments:
          name

        optional arguments:
          -h, --help  show this help message and exit
        """,
        "rule-move": """
        usage: rule-move [-h] --to TO name

        positional arguments:
          name

        optional arguments:
          -h, --help  show this help message and exit
          --to TO
        """,
    ]
}

