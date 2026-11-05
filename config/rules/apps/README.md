# R76S-V2.0.0 application domain inputs

Place the user-provided TXT files here using these exact names:

`amazon-prime.txt`, `chatgpt.txt`, `disney.txt`, `emby.txt`, `hbo-max.txt`, `netflix.txt`, `nintendo.txt`, `telegram.txt`, `tiktok.txt`, `youtube-youtube-tv.txt`, `apple.txt`.

The importer preserves every non-empty source line in the generated manifest. It does not fetch, normalize, delete, or invent domains. Blank lines, comments, malformed lines, duplicates, and missing files are reported. A release build must run the importer without `--allow-missing` and must have zero format errors.

`apple.txt` is the project-maintained Apple ecosystem input. Its comments record the official Apple source and update date. It uses only explicit Apple-published hosts and narrowly scoped Apple-published wildcards; it deliberately does not use `*.apple.com`. AppleEcosystem has no `node`, `outbound`, or `strategy` option, so it follows the system default outbound policy.
