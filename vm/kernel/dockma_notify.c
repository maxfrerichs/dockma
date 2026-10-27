// SPDX-License-Identifier: GPL-2.0
/*
 * Host file changes into guest fsnotify for virtio-fs.
 *
 * The agent writes "<op> <absolute path>" to /proc/fs/dockma-notify, one change
 * per write(). It drops the guest's cached dentry, attributes and pages for the
 * path (the host already has the change) and raises the inotify events a local
 * change would have raised. Nothing goes back to the host.
 *   M  file content or metadata changed: MODIFY, ATTRIB, CLOSE_WRITE
 *   C  created: CREATE (or CREATE|ISDIR) only; the agent follows with M for a
 *      file. C must come before anything in the guest looks the name up: a
 *      lookup caches the new inode, and C would then take it for known.
 *   D  deleted: DELETE on the parent (with ISDIR if the guest knew it as a directory)
 * M on a directory only expires its name. A rename is D old + C new. A C for an
 * inode the guest already had under that name, such as the host's echo of the
 * guest's own mkdir, raises no CREATE.
 */
#include <linux/fs.h>
#include <linux/fsnotify.h>
#include <linux/namei.h>
#include <linux/proc_fs.h>
#include <linux/slab.h>
#include <linux/string.h>
#include "fuse_i.h"

static void dn_modified(struct dentry *dentry)
{
	struct inode *inode = d_inode(dentry);
	struct fuse_conn *fc = get_fuse_conn(inode);

	/* killsb guards fc->mounts, which fuse_ilookup() walks; as fs/fuse/dev.c does. */
	down_read(&fc->killsb);
	fuse_reverse_inval_inode(fc, get_node_id(inode), 0, 0);
	up_read(&fc->killsb);
	/* Separate events: air wants MODIFY, the listen gem ATTRIB or CLOSE_WRITE. */
	fsnotify_dentry(dentry, FS_MODIFY);
	fsnotify_dentry(dentry, FS_ATTRIB);
	fsnotify_dentry(dentry, FS_CLOSE_WRITE);
}

static int dn_apply(char op, const char *path)
{
	const char *slash = strrchr(path, '/');
	struct path parent, child;
	struct dentry *cached;
	struct fuse_conn *fc;
	struct inode *dir;
	struct qstr name;
	char *dirpath;
	int err;

	if (path[0] != '/' || !slash || !slash[1])
		return -EINVAL;
	dirpath = kstrndup(path, max_t(size_t, slash - path, 1), GFP_KERNEL);
	if (!dirpath)
		return -ENOMEM;
	err = kern_path(dirpath, LOOKUP_DIRECTORY, &parent);
	kfree(dirpath);
	if (err)
		return err;
	if (strcmp(parent.dentry->d_sb->s_type->name, "virtiofs")) {
		err = -EXDEV;
		goto out;
	}
	dir = d_inode(parent.dentry);
	fc = get_fuse_conn(dir);
	name = (struct qstr)QSTR_INIT(slash + 1, strlen(slash + 1));

	/* What the guest believed before this change, read without asking the host. */
	cached = try_lookup_noperm(&name, parent.dentry);
	if (IS_ERR(cached)) {
		err = PTR_ERR(cached);
		goto out;
	}

	/*
	 * Expire the cached name so the lookup below revalidates it with the host. Expire only:
	 * plain invalidation detaches mounts on top of it, e.g. a container's volume over a
	 * subdirectory of the share.
	 */
	down_read(&fc->killsb);
	fuse_reverse_inval_entry(fc, get_node_id(dir), 0, &name, FUSE_EXPIRE_ONLY);
	up_read(&fc->killsb);

	if (op == 'D') {
		/* Always: the guest's own unlink leaves no negative dentry to tell an echo by. */
		fsnotify_name(cached && d_is_dir(cached) ? FS_DELETE | FS_ISDIR : FS_DELETE,
			      dir, FSNOTIFY_EVENT_INODE, dir, &name, 0);
		goto put_cached;
	}
	err = kern_path(path, 0, &child);
	if (err)
		goto put_cached;
	/* A mount on the path leads off the share; dn_modified() would misread its inode as FUSE's. */
	if (child.dentry->d_sb != parent.dentry->d_sb) {
		err = -EXDEV;
		goto put_child;
	}
	/*
	 * The guest already had this inode under this name: not new to it. The name comes
	 * from the agent, because child's d_name can change under a guest rename.
	 */
	if (op == 'C') {
		if (!(cached && d_inode(cached) == d_inode(child.dentry)))
			fsnotify_name(d_is_dir(child.dentry) ? FS_CREATE | FS_ISDIR : FS_CREATE,
				      child.dentry, FSNOTIFY_EVENT_DENTRY, dir, &name, 0);
	} else if (!d_is_dir(child.dentry)) {
		dn_modified(child.dentry);
	}
put_child:
	path_put(&child);
put_cached:
	dput(cached);
out:
	path_put(&parent);
	return err;
}

static ssize_t dn_write(struct file *file, const char __user *ubuf, size_t len, loff_t *ppos)
{
	char *buf;
	int err;

	/* Not root in a default container: those lack CAP_SYS_ADMIN. */
	if (!capable(CAP_SYS_ADMIN))
		return -EPERM;
	if (len < 3 || len > PATH_MAX + 2)
		return -EINVAL;
	buf = memdup_user_nul(ubuf, len);
	if (IS_ERR(buf))
		return PTR_ERR(buf);
	if (buf[len - 1] == '\n')
		buf[len - 1] = '\0';
	err = (strchr("MCD", buf[0]) && buf[0] && buf[1] == ' ') ? dn_apply(buf[0], buf + 2) : -EINVAL;
	kfree(buf);
	return err ? err : len;
}

static const struct proc_ops dn_ops = {
	.proc_write = dn_write,
};

static int __init dn_init(void)
{
	return proc_create("fs/dockma-notify", 0200, NULL, &dn_ops) ? 0 : -ENOMEM;
}
late_initcall(dn_init);
