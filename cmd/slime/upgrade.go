package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/internal/daemon"
	"github.com/aldehir/slime/internal/rpc"
)

// Upgrading: a new build of slime replaces the daemon serving. The old
// one stops keeping its layout (daemon.stop with save), the new one
// starts and restores it from model.json, each pane relaunched: the
// programs in them end, the shells come back where they were. Windows
// hear daemon.restarting and reconnect.

func upgradeCommand() *cobra.Command {
	var force bool
	cmd := &cobra.Command{
		Use:   "upgrade",
		Short: "Replace the running daemon with this build, keeping the layout",
		Long: "Stops the daemon running, if it is of an older build than this executable\n" +
			"(--force: of any other build), keeping its workspaces, tabs, and panes in\n" +
			"model.json, and starts this build in its place, which restores them under the\n" +
			"same ids: every pane's command is run again in the directory its shell last\n" +
			"reported. The programs that were running end. Windows reconnect by\n" +
			"themselves; hosts the daemon was logged in to are logged in to again by the\n" +
			"next window that wants them. Prints \"already current\" and does nothing when\n" +
			"the daemon is this build.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			did, err := upgradeDaemon(force, os.Stdout)
			if err != nil {
				return err
			}
			if !did {
				fmt.Println("already current")
			}
			return nil
		},
	}
	cmd.Flags().BoolVar(&force, "force", false, "replace a daemon of any other build, older or newer")
	return cmd
}

// upgradeDaemon replaces the daemon with this build, if it's of
// another: any other with force, else only an older one. It returns
// whether it did. A daemon that isn't running isn't upgraded: the
// caller starts one as usual.
func upgradeDaemon(force bool, out io.Writer) (bool, error) {
	c, err := connect(false)
	if err != nil {
		if strings.Contains(err.Error(), "isn't running") {
			return false, nil
		}
		return false, err
	}
	ours := daemon.CurrentBuild()
	var info rpc.DaemonInfoResult
	if err := c.Call(rpc.DaemonInfo, nil, &info); err != nil {
		c.Close()
		var rerr *rpc.Error
		if errors.As(err, &rerr) && rerr.Code == rpc.CodeMethodNotFound {
			return false, errors.New("the daemon is too old to keep its layout: slime stop it first")
		}
		return false, err
	}
	theirs := info.Build
	switch {
	case theirs.ID == ours.ID:
		c.Close()
		return false, nil
	case !force && !daemon.Newer(ours, theirs):
		c.Close()
		return false, fmt.Errorf("the daemon's build %s (%s) is newer than this one's %s (%s); --force replaces it anyway",
			theirs.ID, time.Unix(theirs.Time, 0).Format(time.RFC3339), ours.ID, time.Unix(ours.Time, 0).Format(time.RFC3339))
	}
	var hosts rpc.HostListResult
	if err := c.Call(rpc.HostList, nil, &hosts); err == nil {
		var connected []string
		for _, h := range hosts.Hosts {
			if h.State == rpc.HostConnected || h.State == rpc.HostConnecting {
				connected = append(connected, h.Dest)
			}
		}
		if len(connected) > 0 {
			fmt.Fprintf(out, "hosts connected, which the restart drops (their panes stay): %s\n", strings.Join(connected, ", "))
		}
	}
	old := info.PID
	if err := c.Call(rpc.DaemonStop, rpc.DaemonStopParams{Save: true, Build: ours}, nil); err != nil {
		c.Close()
		return false, fmt.Errorf("stopping pid %d: %w", old, err)
	}
	c.Close()
	name, err := daemon.Address()
	if err != nil {
		return false, err
	}
	// Wait for the old daemon to close its listener, then start ours
	// with its arguments.
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
		conn, err := daemon.Dial(ctx, name)
		cancel()
		if err != nil && isNotRunning(err) {
			break
		}
		if conn != nil {
			conn.Close()
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err := startDaemon(stripServeArgs(info.Args)...); err != nil {
		return false, fmt.Errorf("starting slime: %w", err)
	}
	deadline = time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		conn, err := daemon.Dial(ctx, name)
		cancel()
		if err != nil {
			continue
		}
		nc, err := daemon.NewClient(conn)
		if err != nil {
			conn.Close()
			continue
		}
		pid, build := nc.Hello.PID, nc.Hello.Build
		nc.Close()
		if pid != old && build.ID == ours.ID {
			fmt.Fprintf(out, "slime upgraded: build %s (pid %d) replaced %s (pid %d)\n", ours.ID, pid, theirs.ID, old)
			return true, nil
		}
	}
	return false, errors.New("the new daemon didn't start in time; see slime.log")
}

// stripServeArgs is a daemon's serve arguments without the log, which
// startDaemon sets itself.
func stripServeArgs(args []string) []string {
	var out []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--log" && i+1 < len(args):
			i++
		case strings.HasPrefix(a, "--log="):
		default:
			out = append(out, a)
		}
	}
	return out
}
