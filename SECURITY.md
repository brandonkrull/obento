# Security

obento sets up a server that holds a family's photos, passwords and files, and `install.sh` runs as root. If you
find a way it could expose data, let someone in, or run something it shouldn't, please report it privately:
the repository's **Security** tab → **Report a vulnerability**. Please don't open a public issue.

Say what you found, how to reproduce it, and which commit you looked at. You'll get a reply within a week.

**Running your own copy**: your server installs whatever is on the branch it pulls. Pull from your own fork,
read changes before `obento update`, and keep secrets in `.env`, which is never committed.
