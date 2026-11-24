==============================================================================
  join-freeipa.sh  -  Join an Ubuntu workstation to FreeIPA
==============================================================================

WHAT IT IS
----------
A single bash script that installs the FreeIPA client on an Ubuntu laptop,
sets its hostname, updates /etc/hosts, joins it to the FreeIPA domain and
then checks that the join really worked. It shows coloured progress on
screen (banner, numbered steps, spinners, tick/cross marks and a summary
box) and writes the full output of every command to a log file.


DOMAIN SETTINGS USED
--------------------
  IPA server ........ ipa.dic.evollabs.ae
  Kerberos realm .... DIC.EVOLLABS.AE
  DNS domain ........ next-ai.me
  Hostname format ... <name>.dic.next-ai.me   (e.g. lap-ali-01.dic.next-ai.me)
  Join account ...... asid   (only used to join the laptop to the domain;
                              it is NOT the person who will use the laptop)

These values are in the "Configuration" block at the top of the script.


REQUIREMENTS
------------
  - Ubuntu (tested on 22.04 / 24.04)
  - Internet access to the Ubuntu package mirrors
  - Network access to ipa.dic.evollabs.ae
    (ports 443 HTTPS, 88 Kerberos, 389 LDAP)
  - Run as root (sudo)


HOW TO RUN
----------
  1. Copy join-freeipa.sh to the laptop.
  2. Open a terminal in that folder and run:

        chmod 700 join-freeipa.sh
        sudo bash join-freeipa.sh

  3. When asked, type the short hostname for the laptop (e.g. lap-ali-01)
     and confirm the full name it shows.
  4. Wait for the summary box. If it is green, answer "y" to reboot.
  5. After reboot the laptop user logs in with THEIR OWN IPA account.
     Their home folder is created automatically on first login.
  6. Delete join-freeipa.sh from the laptop.


WHAT THE SCRIPT DOES, STEP BY STEP
----------------------------------
STEP 1 - Pre-flight checks
  - Makes sure it is running as root.
  - Checks the OS is Ubuntu (warns if not).
  - Checks ipa.dic.evollabs.ae resolves in DNS (stops if not).
  - Tests ports 443, 88 and 389 on the IPA server (warns if closed).
  - If the laptop is already joined to FreeIPA, asks whether to
    [r]einstall (leave the domain and join again) or [q]uit.
    If leaving the domain fails, the script stops before changing anything.

STEP 2 - Install the FreeIPA client
  - Pre-fills the Kerberos realm and server so no blue setup dialogs appear.
  - Runs apt-get update.
  - Installs the freeipa-client package (brings SSSD, Kerberos tools, etc.).

STEP 3 - Set the hostname
  - Asks for a short hostname, cleans it up (lowercase, no spaces) and
    checks it is valid (letters, digits and "-", max 63 characters).
  - Shows the full name <name>.dic.next-ai.me and asks for confirmation.
  - Saves the old hostname, then sets the new one with hostnamectl.

STEP 4 - Update /etc/hosts
  - Makes a backup:  /etc/hosts.bak.<date-time>
  - Removes any old 127.0.1.1 line and adds, right after the 127.0.0.1 line:
        127.0.1.1   <name>.dic.next-ai.me <name>
  - Writes the new file to a temp file first and only replaces /etc/hosts
    if that succeeded, so /etc/hosts can never end up empty.
  - Shows the first lines of the new /etc/hosts.

STEP 5 - Join FreeIPA
  Runs:
    ipa-client-install --domain=next-ai.me --server=ipa.dic.evollabs.ae
                       --realm=DIC.EVOLLABS.AE --hostname=<fqdn>
                       --principal=asid --password=<join password>
                       --mkhomedir --enable-dns-updates
                       --force-join --unattended

    --mkhomedir           create home folders on first login
    --enable-dns-updates  laptop registers its own DNS record in IPA
    --force-join          rejoin even if this hostname already exists in IPA
    --unattended          no questions; the password is supplied by the script

  This configures SSSD, Kerberos, the host keytab, PAM/NSS and certificates.

STEP 6 - Verify the join
  Each check shows a tick (pass) or cross (fail):
  - /etc/ipa/default.conf exists
  - its "server =" line is exactly ipa.dic.evollabs.ae
  - the SSSD service is running
  - the host keytab /etc/krb5.keytab exists
  - Kerberos login as asid works (kinit)
  - a Kerberos ticket was issued (klist)
  - the IPA server knows this host (ipa host-show)
  - IPA accounts can be looked up through SSSD (getent -s sss passwd asid)
  - home-folder creation is enabled in PAM
  The Kerberos test uses a temporary ticket cache that is deleted afterwards,
  so any existing root tickets are not touched.

SUMMARY
  A box shows hostname, domain, realm, server, number of passed / failed
  checks and the log path. Green = joined OK, red = some checks failed.
  On success it offers to reboot (Enter / no input = no reboot).


SAFETY FEATURES
---------------
  - Automatic rollback: if the join fails (or you press Ctrl+C before it
    finishes), the old hostname and the original /etc/hosts are restored.
    Once the join has succeeded, nothing is rolled back.
  - Ctrl+C also stops any command still running in the background
    (apt / dpkg / ipa-client-install), so nothing is left half-running.
  - If there is no keyboard input (Ctrl+D or stdin closed), the script
    stops instead of looping.


FILES AND LOGS
--------------
  /var/log/freeipa-join.log         full output of this script (root only)
  /var/log/ipaclient-install.log    detailed log from ipa-client-install
  /etc/hosts.bak.<date-time>        backup of /etc/hosts before the change
  /etc/ipa/default.conf             IPA client config created by the join


EXIT CODES
----------
  0     joined successfully (or you chose [q]uit)
  1     an error occurred, or one or more checks failed
  130   interrupted with Ctrl+C


TROUBLESHOOTING
---------------
  - "Cannot resolve ipa.dic.evollabs.ae"
        Fix the laptop's DNS / network, then run the script again.
  - Port warnings in step 1
        A firewall may be blocking the IPA server; the join may fail.
  - ipa-client-install failed
        Read the red log lines on screen, then
        /var/log/ipaclient-install.log for details.
        Hostname and /etc/hosts have already been rolled back.
  - Laptop was joined before
        Run the script again and choose [r]einstall.
  - To leave the domain manually:
        sudo ipa-client-install --uninstall


SECURITY NOTES
--------------
  - The script contains the password of the join account (asid).
    Keep it private: chmod 700, do not email it or put it on shared drives.
  - Delete the script from each laptop after it has been joined.
  - While step 5 runs, the password is briefly visible in the process list
    (ps) to other users on that laptop. Run the script when nobody else is
    logged in.
  - Change the asid password once all laptops have been joined.
