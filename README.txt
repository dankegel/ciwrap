=== Big Fat Buildbot Example =============================================

Dan Kegel
kegel.com
October 2012

====== Prelude ======

So, you're a software engineer setting up a continuous integration
system for a bunch of related libraries and executables, written in a mix
of languages, targeting several platforms, and you're considering Buildbot as
your continuous integration tool.
If you're having trouble coming up the Buildbot learning curve, you're not
alone! (See e.g. http://jacobian.org/writing/buildbot/ci-is-hard/ )

Buildbot has a tutorial at http://buildbot.net/buildbot/docs/current/tutorial
If you haven't stepped through it yet, go do so now.
It's a useful introduction... but it only just barely scratches the surface.

Buildbot's reference manual provides the missing details, but is challenging
to understand fully.  Nevertheless, new users should absolutely read it,
and try to understand at least the key concepts before diving in.  At the
risk of oversimplifying, the barest minimum you need to know is:
- a Buildbot is ChangeSources + Schedulers + Builders + BuildFactories + Slaves
- a ChangeSource watches e.g. a git repository and alerts Schedulers to changes
- a Scheduler watches ChangeSources and the clock, decides when to run a Builder
- a Builder runs the Steps in a BuildFactory on a Slave
- a BuildFactory is just a list of Steps, rather like a script
- a Slave is just a dumb remote execution agent
Now go read the manual ( http://buildbot.net/buildbot/docs/current/manual ).
I'll wait. ...
Is your head exploding yet?  If not, you can stop reading now.

In the thread
http://comments.gmane.org/gmane.comp.python.buildbot.devel/8396
John Carr suggested that Buildbot would be easier to learn if it included
configuration helpers to simplify the most common cases.
One way to approach that might be to extend the current tutorial
configuration to handle a few more projects, then collect the common
code for those projects's buildbot configuration into a Python class,
and then add a new chapter to the tutorial based on that class.

Here's a stab at doing that, and then some.

====== Example ======

This is a production environment boiled down to a small self-
contained example, so it's a bit more ambitious than most tutorials.

To add more dramatic tension, this example handles native C/C++ code,
not just Python, on both Linux and Windows.

It also integrates cleanly into the system startup of many recent Linuxes
(using upstart) and Microsoft Windows (using cygwin's cygrunsrv).

Also, as an olive branch to developers who are not part of the build team
and who want to duplicate exactly what Buildbot does without using Buildbot,
it cleanly separates buildbot configuration from project-specific build steps
by segregating the latter into a project-specific but non-Buildbot-specific
script (in this example, it's called 'buildshim', but the name isn't important).

Finally, it also shows one way to use Linux Containers to isolate builds --
and, since that requires a tiny patch to buildbot, the example also shows
how to build and install buildbot from source automatically.

You might want to run this in a virtual machine, since it is
rather free with root privileges, and does things like install
packages without asking.  (I recommend using vmware player with an
ubuntu 12.04 guest.  virtualbox also works, except that running ephemeral
lxc containers inside virtualbox seems to be broken, see
http://www.mail-archive.com/lxc-users@lists.sourceforge.net/msg04027.html )

In this example,
- Each project has its own buildbot master and slaves
- Each project has a directory containing at least three things:
  a) a script named 'buildshim' which takes args like 'compile' and turns
  them into 'make', etc.
  b) the master.cfg for the project's buildbot master
  c) the config.json listing the slaves and branches to build
- For ease of keeping config in git, Buildbot state files are segregated
  into a separate directory
- A common python class is used to make the master.cfg files shorter and
  a bit more declarative
- A common script, bmaster.sh, installs and initiales buildbot masters
- A common script, bslave.sh, installs and initializes buildbot slaves
- The system's service manager starts Buildbot masters and slaves
- LXC support is optional, and implemented by a separate script,
  bvslave-lxc.sh, which wraps around bslave.sh and uses ephemeral containers
  to provide a fresh environment for each build.

Or, looking at the example from the point of view of the files it contains:

bccache.sh        - show ccache stats for project (run on slave or lxc host)
bdemo.sh          - sample showing how to use the other scripts
bvdemo.sh         - sample showing how to use the other scripts with LXC
blogs.sh          - show logs for a project
bmaster.sh        - administer buildmaster for a project
bservice.sh       - tell system service manager to start or stop all buildbots
bvslave-lxc.sh    - administer virtual lxc buildslaves for a project
bslave.sh         - administer buildslaves for a project
pyflakes/master.cfg - buildbot config for pyflakes project; uses buildshim
pyflakes/config.json- list of branches to build, and slaves to build them on
pyflakes/buildshim  - standalone build steps for pyflakes
pyflakes/slot.txt   - offset from 8010 for the web status page for pyflakes
hello/master.cfg    - buildbot config for pyflakes project; uses buildshim
hello/config.json   - list of branches to build, and slaves to build them on
hello/buildshim     - standalone build steps for hello
hello/slot.txt      - offset from 8010 for the web status page for hello
zlib/master.cfg     - buildbot config for zlib project; uses buildshim
zlib/config.json    - list of branches to build, and slaves to build them on
zlib/buildshim      - standalone build steps for zlib (needs helpers on windows)
zlib/slot.txt       - offset from 8010 for the web status page for zlib
zlib/bcheck.bat     - standalone helper to invoke tests via visual studio
zlib/bcompile.bat   - standalone helper to compile with visual studio
zlib/bconfigure.bat - standalone helper to run cmake in preparation for bcompile

====== A word about ephemeral state ======

Ephemeral state of the installed master are kept in the directory
~/master-state.  (The only real file in master-state that is
not totally ephemeral are the state.sqlite files, and blowing those away
just means losing build history.)  master-state contains the directory
'sandbox', a clean python environment managed by python's virtualenv tool.

Each project (pyflakes, hello, zlib, etc) has its own buildbot master.
The ephemeral state for each buildbot master lives in the directory
~/master-state/sandbox/$PROJECT
This contains not only twistd.log (the log file for the project's master),
but also a symlink back to master.cfg.

Likewise, state of the installed slaves are kept in the directory
~/slave-state.
Each project has many buildslaves; each buildslave has a directory
~/slave-state/$OS/$PROJECT-$HOSTNAME, where OS is the target operating
system being built for, and HOSTNAME is the hostname of the machine the
buildslave is running on.  This directory exists only on the slave
machine.

Except when using LXC, when the directory also exists on the machine
hosting the virtual slaves.
When using LXC, the ~/slave-state directory is shared between
the host and the container, so even after the ephemeral container
exits, you can see its build directory, and ccache remembers
compiled .o files between builds.

Because of the separation between ephermeral state and configuration,
you can completely delete ~/master-state and ~/slave-state without losing
any configuration info, and you can merrily use git commit -a without
having to create a monster .gitignore.

====== A word about secret config values ======

This example keeps them in the file ~/myconfig.json so they don't leak
into git.

====== Starting the example on Linux ======

Let's start with just one project (Pyflakes) on one platform (Ubuntu 12.04
or 12.10), with both buildmaster and buildslave on the same machine.

Unpack the ciwrap tarball or check out ciwrap with git.
Go into the directory that created, e.g.
   cd ~/ciwrap

Copy the sample secrets file with the command
   cp example-secrets.json ~/myconfig.json

Install buildbot with the commands
   ./bmaster.sh install
   ./bslave.sh install

Edit pyflakes/master.cfg and replace the slave names zlib-* with
your hostname, then set up the master and slave with the command
   ./bmaster.sh init pyflakes
   ./bslave.sh init pyflakes

Start the buildbots with the command
   ./bservice.sh start
(Rebooting would do, too; bservice.sh is just a convenience for testing.)

Verify that the services are still up with the command
   ./bservice.sh status

View the last ten lines of the buildbot's log files with the command
   ./blogs.sh pyflakes tail
and verify manualy that there are no obvious errors.

Launch a web browser and view the page http://localhost:8010
You should see the status page for the Pyflakes buildbot, and
after you log in with the web username and password from the secrets file,
you should be able to force a build, which should succeed.

Once that works, repeat with the 'hello' and 'zlib' projects; their status
pages are at http://localhost:8011 and http://localhost:8012, respectively.
(See slot.txt for how the port number is set.)

====== Adding Windows buildslaves ======

I like my Posix commandline environment, so when I use Windows, I always
install Cygwin.  Cygwin seems to be solid enough to run lightweight services
these days, so for ease of porting the example, I used Cygwin for everything
(except for compiling zlib, where I use Visual Studio 2010 Express.)

Buildbot's master doesn't work on cygwin (some sqlite problem), but that's
ok, we'll just point the Windows buildslave at the Linux buildmaster you
set up previously.

Here's how to get this example going on cygwin.  (You'll probably
want to run Cygwin Terminal as an administrator, and either log in as user
buildbot or change the kludgy BUILDUSER=buildbot line in *.sh.)

1) download http://cygwin.com/setup.exe to c:\cygpkgs\setup.exe

2) start it, select a nearby mirror, and install the six packages
     bzip2 git subversion tar vim wget

3) In a cygwin terminal, install apt-cyg with the commands
     svn --force export http://apt-cyg.googlecode.com/svn/trunk /bin
     chmod +x /bin/apt-cyg

4) In ~/.bashrc, add the lines
     alias apt-cyg=apt-cyg -m http://cygwin.mirrors.pair.com/
     alias apt-cygports=apt-cyg -m ftp://sourceware.org/pub/cygwinports/
   (Be careful, sometimes if you copy and paste that, the quotes get broken.)
   and do
     . ~/.bashrc
5) Do
     apt-cyg install python
     apt-cygports install python-setuptools

6) Exit all cygwin windows, get a plain old cmd.exe window,
   and rebase all the cygwin binaries with the commands
     cd \cygwin\bin
     ash
     PATH=. rebaseall -v

7) Get a fresh Cygwin terminal, and repeat the earlier steps to run a slave,
   slightly tweaked to point at the linux buildmaster:

    Unpack the ciwrap tarball or check out ciwrap with git.
    Go into the directory that created, e.g.
       cd ~/ciwrap

    Copy the sample secrets file with the command
       cp example-secrets.json ~/myconfig.json

    Install buildbot with the commands
       ./bslave.sh install

8) On the master Linux box, add a new slave entry in pyflakes/master.cfg
   according to the scheme
     projectname-hostname
   e.g. if your windows box's hostname is foo, then you'd add entries for
     pyflakes-foo
   into the slave lists in pyflakes/master.cfg
   Sanity check your changes with
     ./bmaster.sh check pyflakes
   Then restart the masters, and make sure everything still runs, with the
   commands
     ./bservice.sh stop
     ./bservice.sh start
     ./bservice.sh status
   (FIXME: bservice.sh should take a project name as an optional argument.)

9) Back on the slave, initialize and start the pyflakes slave with the usual
   commands, but this time pointing at the other master:
     MASTER=linuxhostname ./bslave.sh init pyflakes
     ./bservice.sh start
   (Rebooting would do, too; bservice.sh is just a convenience for testing.)

10) Verify that the services are still up with the command
     ./bservice.sh status

11) View the last ten lines of the buildbot's log files with the command
      ./blogs.sh pyflakes tail
    and verify manualy that there are no obvious errors.

12) As usual, launch a web browser and view the page http://linuxhostname:8010
    On the Pyflakes status page, you should now see the windows buildbot.
    After you log in with the web username and password from the secrets file,
    you should be able to force a build, which should succeed.
    (FIXME: you'll need to take the linux slave offline before forcing a
    build is sure to do anything with the windows slave.  I should parameterize
    builder name by target platform.)

Once pyflakes is building on windows, try hello, that should work, too.

The zlib example uses Visual C++ Express 2010, so before trying that, do:

1) Download and install Visual C++ Express 2010 from microsoft.com/visualstudio

2) As a sanity check, you might want to get a tempororary copy of the zlib
   source tree and verify that the example's helper batch files properly
   compile it.
   In a Cygwin terminal, do
      cd ~
      apt-cyg install cmake
      wget http://zlib.net/zlib-1.2.7.tar.gz
      tar -xzvf zlib-1.2.7.tar.gz
      cd zlib-1.2.7
   Then in a fresh CMD window (NOT in cmd inside the cygwin terminal!), do
      cd \cygwin\home\YOURUSERNAME\zlib-1.2.7
      ..\ciwrap\zlib\bconfigure
      cd ..
      ..\ciwrap\zlib\bcompile
      cd ..
      ..\ciwrap\zlib\bcheck
      cd ..
   and verify that btmp\Release has binaries in it, and the tests passed.
   Exit out of this cmd window.
   (It's a little lame that bconfigure.bat et al change the current
   directory, but making cd or popd the last command in the batch file would
   reset the exit status to zero, preventing buildbot from sensing errors.)

3) Remove the temporary zlib source tree and the build.
      cd ~
      rm -rf ~/zlib-1.2.7

If that little sanity check passes, you should be able to start the zlib
buildslave and control it from the buildmaster.

====== TROUBLESHOOTING BUILDS ======

The clean way to debug things is to tweak the buildshim (possibly to add
a patch), then use the web interface to restart the whole job.

Before you do that, though, you might want to test out the fix by 
logging into the slave, cd'ing to the job's work directory, tweaking the 
source tree, and rerunning just the failed part manually, e.g.
  cd ~/slave-state/cygwin/foobar-win7-bb01/foobar-win7-master/build
  ~/ciwrap-git/foobar/buildshim check
(If the buildshim has a working uninstall_deps step, you might also
need to run its install_deps step first.)

This is easy if you're not using LXC or Cygwin. 

With Cygwin, since bslave.sh doesn't run jobs as the buildbot user (yet),
you might need to put those two lines into a shell script ~/check.sh,
then install it as a service, e.g.
 cygrunsrv -i mycheck -p /bin/sh -a /home/buildbot/mycheck.sh --type=manual
and then start and watch it like this:
 cygrunsrv --stop mycheck; cygrunsrv --start mycheck; tail -f /var/log/mycheck.log
Then you can reasonably quickly iterate, making changes to the source
tree and then rerunning that command.

With LXC, ssh'ing to the slave is only slightly annoying; to find the name of
the slave machines, do 'lxc-ls', then do e.g.
  cd ~/ciwrap-git
  ./lxc-local/lxc-ssh big-long-hostname-from-lxc-ls

====== COPYING ======

ciwrap is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free
Software Foundation, version 2.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
Public License for more details.

For full details, please see the file named COPYING in the top directory
of the source tree. You should have received a copy of the GNU General
Public License along with this program. If not, see
<http://www.gnu.org/licenses/>.

