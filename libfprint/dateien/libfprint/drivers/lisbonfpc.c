/*
 * lisbonfpc: fingerprint sensor of the Motorola Moto G60s (lisbon)
 *
 * The sensor sits behind the TEE of the phone: enrollment, matching and template storage happen in the secure
 * world, reached through the vendor fingerprint HAL. A local service (lisbon-fpc-bridge) talks to that HAL and
 * offers a small socket protocol; this driver is its client and makes the sensor an ordinary match-on-chip
 * device with storage for libfprint/fprintd. No image ever reaches this driver.
 *
 * The device appears when the environment variable LISBON_FPC_BRIDGE names the socket of the bridge (set for
 * fprintd by a systemd drop-in) and the bridge answers. Protocol (one ASCII message per SOCK_SEQPACKET packet):
 *   HELLO -> OK 1 <stages>          ENROLL -> STAGE <remaining>... then OK <finger id>
 *   IDENTIFY -> OK <finger id>|OK 0 LIST -> OK <finger id>...     DELETE <finger id>|DELETE 0 -> OK
 *   CANCEL (ends a running ENROLL/IDENTIFY with ERR canceled)     errors: ERR <reason>
 *
 * Copyright (C) 2026 lisbon-mainline contributors
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * SPDX-License-Identifier: LGPL-2.1-or-later
 */

#define FP_COMPONENT "lisbonfpc"

#include <errno.h>
#include <glib-unix.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include "drivers_api.h"

#define LISBONFPC_MSG_MAX 512
#define LISBONFPC_DEFAULT_STAGES 12
#define LISBONFPC_TIMEOUT_MS 3000

struct _FpiDeviceLisbonFpc
{
  FpDevice parent;
  int      fd;
  guint    watch;
  gint     stages;
  gint     stage;
  guint    remaining;
};

G_DECLARE_FINAL_TYPE (FpiDeviceLisbonFpc, fpi_device_lisbonfpc, FPI, DEVICE_LISBONFPC, FpDevice)
G_DEFINE_TYPE (FpiDeviceLisbonFpc, fpi_device_lisbonfpc, FP_TYPE_DEVICE)

static const FpIdEntry id_table[] = {
  { .virtual_envvar = "LISBON_FPC_BRIDGE", .driver_data = 0 },
  { .virtual_envvar = NULL }
};

/* ------------------------------------------------------------------ socket */

static int
lisbonfpc_connect (FpDevice *device, GError **error)
{
  const gchar *path = fpi_device_get_virtual_env (device);
  struct sockaddr_un addr = { .sun_family = AF_UNIX };
  int fd;

  if (!path || strlen (path) >= sizeof (addr.sun_path))
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_NOT_SUPPORTED, "Invalid bridge socket path");
      return -1;
    }
  strcpy (addr.sun_path, path);
  fd = socket (AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
  if (fd < 0 || connect (fd, (struct sockaddr *) &addr, sizeof (addr)) < 0)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_NOT_SUPPORTED,
                   "Fingerprint bridge not reachable: %s", g_strerror (errno));
      if (fd >= 0)
        close (fd);
      return -1;
    }
  return fd;
}

static gboolean
lisbonfpc_send (int fd, const gchar *msg, GError **error)
{
  if (send (fd, msg, strlen (msg), MSG_NOSIGNAL) < 0)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO,
                   "Fingerprint bridge: %s", g_strerror (errno));
      return FALSE;
    }
  return TRUE;
}

/* Blocking request for the short setup exchange (HELLO); the bridge answers immediately. */
static gboolean
lisbonfpc_hello (int fd, gint *stages, GError **error)
{
  struct pollfd pfd = { .fd = fd, .events = POLLIN };
  char msg[LISBONFPC_MSG_MAX];
  ssize_t len;
  int version = 0, n = 0;

  if (!lisbonfpc_send (fd, "HELLO", error))
    return FALSE;
  if (poll (&pfd, 1, LISBONFPC_TIMEOUT_MS) <= 0 ||
      (len = recv (fd, msg, sizeof (msg) - 1, 0)) <= 0)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_PROTO, "Fingerprint bridge does not answer");
      return FALSE;
    }
  msg[len] = 0;
  if (sscanf (msg, "OK %d %d", &version, &n) != 2 || version != 1 || n <= 0 || n > 64)
    {
      g_set_error (error, FP_DEVICE_ERROR, FP_DEVICE_ERROR_NOT_SUPPORTED,
                   "Fingerprint bridge not ready: %s", msg);
      return FALSE;
    }
  *stages = n;
  return TRUE;
}

static GError *
lisbonfpc_error (const gchar *reason)
{
  if (g_str_equal (reason, "canceled"))
    return g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CANCELLED, "Operation was cancelled");
  if (g_str_equal (reason, "busy"))
    return fpi_device_error_new (FP_DEVICE_ERROR_BUSY);
  if (g_str_equal (reason, "nospace"))
    return fpi_device_error_new (FP_DEVICE_ERROR_DATA_FULL);
  if (g_str_equal (reason, "unavailable"))
    return fpi_device_error_new_msg (FP_DEVICE_ERROR_REMOVED, "Fingerprint HAL not available");
  return fpi_device_error_new_msg (FP_DEVICE_ERROR_GENERAL, "Fingerprint HAL: %s", reason);
}

/* ------------------------------------------------------------------ prints */

static FpPrint *
lisbonfpc_print_new (FpDevice *device, guint32 fid)
{
  FpPrint *print = fp_print_new (device);

  fpi_print_set_type (print, FPI_PRINT_RAW);
  fpi_print_set_device_stored (print, TRUE);
  g_object_set (print, "fpi-data", g_variant_new ("(u)", fid), NULL);
  return print;
}

static guint32
lisbonfpc_print_fid (FpPrint *print)
{
  g_autoptr(GVariant) data = NULL;
  guint32 fid = 0;

  g_object_get (print, "fpi-data", &data, NULL);
  if (data && g_variant_check_format_string (data, "(u)", FALSE))
    g_variant_get (data, "(u)", &fid);
  return fid;
}

/* ------------------------------------------------------------------ answers of the bridge */

static void
lisbonfpc_complete_error (FpDevice *device, GError *error)
{
  switch (fpi_device_get_current_action (device))
    {
    case FPI_DEVICE_ACTION_ENROLL:
      fpi_device_enroll_complete (device, NULL, error);
      break;

    case FPI_DEVICE_ACTION_VERIFY:
      fpi_device_verify_complete (device, error);
      break;

    case FPI_DEVICE_ACTION_IDENTIFY:
      fpi_device_identify_complete (device, error);
      break;

    case FPI_DEVICE_ACTION_LIST:
      fpi_device_list_complete (device, NULL, error);
      break;

    case FPI_DEVICE_ACTION_DELETE:
      fpi_device_delete_complete (device, error);
      break;

    case FPI_DEVICE_ACTION_CLEAR_STORAGE:
      fpi_device_clear_storage_complete (device, error);
      break;

    case FPI_DEVICE_ACTION_NONE:
    case FPI_DEVICE_ACTION_PROBE:
    case FPI_DEVICE_ACTION_OPEN:
    case FPI_DEVICE_ACTION_CLOSE:
    case FPI_DEVICE_ACTION_CAPTURE:
    default:
      g_error_free (error);
      break;
    }
}

static void
lisbonfpc_enroll_message (FpiDeviceLisbonFpc *self, const gchar *msg)
{
  FpDevice *device = FP_DEVICE (self);
  guint value;

  if (sscanf (msg, "STAGE %u", &value) == 1)
    {
      if (self->remaining && value >= self->remaining)
        {
          /* sample not accepted (no new area) */
          fpi_device_enroll_progress (device, self->stage, NULL,
                                      fpi_device_retry_new (FP_DEVICE_RETRY_GENERAL));
          return;
        }
      self->stage += self->remaining ? (gint) (self->remaining - value) : 1;
      self->stage = MIN (self->stage, self->stages - 1);
      self->remaining = value;
      fpi_device_enroll_progress (device, self->stage, NULL, NULL);
    }
  else if (sscanf (msg, "OK %u", &value) == 1 && value)
    {
      FpPrint *print = NULL;

      fpi_device_get_enroll_data (device, &print);
      fpi_print_set_type (print, FPI_PRINT_RAW);
      fpi_print_set_device_stored (print, TRUE);
      g_object_set (print, "fpi-data", g_variant_new ("(u)", value), NULL);
      if (self->stage < self->stages)
        fpi_device_enroll_progress (device, self->stages, NULL, NULL);
      fpi_device_enroll_complete (device, g_object_ref (print), NULL);
    }
  /* ACQ: per-sample quality; STAGE already tells whether a sample counted */
}

static void
lisbonfpc_match_message (FpiDeviceLisbonFpc *self, const gchar *msg)
{
  FpDevice *device = FP_DEVICE (self);
  FpiDeviceAction action = fpi_device_get_current_action (device);
  guint value;

  if (sscanf (msg, "OK %u", &value) != 1)
    return;	/* ACQ */

  if (action == FPI_DEVICE_ACTION_VERIFY)
    {
      FpPrint *print = NULL;

      fpi_device_get_verify_data (device, &print);
      if (value && value == lisbonfpc_print_fid (print))
        fpi_device_verify_report (device, FPI_MATCH_SUCCESS, lisbonfpc_print_new (device, value), NULL);
      else
        fpi_device_verify_report (device, FPI_MATCH_FAIL, NULL, NULL);
      fpi_device_verify_complete (device, NULL);
    }
  else
    {
      GPtrArray *gallery = NULL;
      FpPrint *match = NULL;

      fpi_device_get_identify_data (device, &gallery);
      for (guint i = 0; value && gallery && i < gallery->len; i++)
        {
          FpPrint *p = g_ptr_array_index (gallery, i);

          if (lisbonfpc_print_fid (p) == value)
            {
              match = p;
              break;
            }
        }
      fpi_device_identify_report (device, match, value ? lisbonfpc_print_new (device, value) : NULL, NULL);
      fpi_device_identify_complete (device, NULL);
    }
}

static void
lisbonfpc_message (FpiDeviceLisbonFpc *self, const gchar *msg)
{
  FpDevice *device = FP_DEVICE (self);
  FpiDeviceAction action = fpi_device_get_current_action (device);

  if (g_str_has_prefix (msg, "ERR "))
    {
      fp_dbg ("bridge: %s", msg);
      lisbonfpc_complete_error (device, lisbonfpc_error (msg + 4));
      return;
    }

  switch (action)
    {
    case FPI_DEVICE_ACTION_ENROLL:
      lisbonfpc_enroll_message (self, msg);
      break;

    case FPI_DEVICE_ACTION_VERIFY:
    case FPI_DEVICE_ACTION_IDENTIFY:
      lisbonfpc_match_message (self, msg);
      break;

    case FPI_DEVICE_ACTION_LIST:
      if (g_str_has_prefix (msg, "OK"))
        {
          g_auto(GStrv) ids = g_strsplit (msg + 2, " ", -1);
          GPtrArray *prints = g_ptr_array_new_with_free_func (g_object_unref);

          for (gint i = 0; ids[i]; i++)
            {
              guint64 fid = g_ascii_strtoull (ids[i], NULL, 10);

              if (fid && fid <= G_MAXUINT32)
                g_ptr_array_add (prints, g_object_ref_sink (lisbonfpc_print_new (device, fid)));
            }
          fpi_device_list_complete (device, prints, NULL);
        }
      break;

    case FPI_DEVICE_ACTION_DELETE:
      if (g_str_equal (msg, "OK"))
        fpi_device_delete_complete (device, NULL);
      break;

    case FPI_DEVICE_ACTION_CLEAR_STORAGE:
      if (g_str_equal (msg, "OK"))
        fpi_device_clear_storage_complete (device, NULL);
      break;

    case FPI_DEVICE_ACTION_NONE:
    case FPI_DEVICE_ACTION_PROBE:
    case FPI_DEVICE_ACTION_OPEN:
    case FPI_DEVICE_ACTION_CLOSE:
    case FPI_DEVICE_ACTION_CAPTURE:
    default:
      fp_dbg ("bridge message without action: %s", msg);
      break;
    }
}

static gboolean
lisbonfpc_readable (gint fd, GIOCondition condition, gpointer user_data)
{
  FpiDeviceLisbonFpc *self = FPI_DEVICE_LISBONFPC (user_data);
  char msg[LISBONFPC_MSG_MAX];
  ssize_t len = recv (fd, msg, sizeof (msg) - 1, MSG_DONTWAIT);

  if (len < 0 && (errno == EAGAIN || errno == EINTR))
    return G_SOURCE_CONTINUE;
  if (len <= 0)
    {
      fp_warn ("fingerprint bridge closed the connection");
      self->watch = 0;
      lisbonfpc_complete_error (FP_DEVICE (self),
                                fpi_device_error_new_msg (FP_DEVICE_ERROR_REMOVED, "Fingerprint bridge gone"));
      return G_SOURCE_REMOVE;
    }
  msg[len] = 0;
  lisbonfpc_message (self, msg);
  return G_SOURCE_CONTINUE;
}

static void
lisbonfpc_request (FpDevice *device, const gchar *msg)
{
  FpiDeviceLisbonFpc *self = FPI_DEVICE_LISBONFPC (device);
  GError *error = NULL;

  if (self->fd < 0)
    error = fpi_device_error_new (FP_DEVICE_ERROR_NOT_OPEN);
  else
    lisbonfpc_send (self->fd, msg, &error);
  if (error)
    lisbonfpc_complete_error (device, error);
}

/* ------------------------------------------------------------------ device operations */

static void
lisbonfpc_probe (FpDevice *device)
{
  GError *error = NULL;
  gint stages = 0;
  int fd = lisbonfpc_connect (device, &error);

  if (fd >= 0)
    {
      lisbonfpc_hello (fd, &stages, &error);
      close (fd);
    }
  if (!error)
    fpi_device_set_nr_enroll_stages (device, stages);
  fpi_device_probe_complete (device, "lisbon-fpc-tee", NULL, error);
}

static void
lisbonfpc_open (FpDevice *device)
{
  FpiDeviceLisbonFpc *self = FPI_DEVICE_LISBONFPC (device);
  GError *error = NULL;
  gint stages = 0;

  self->fd = lisbonfpc_connect (device, &error);
  if (self->fd >= 0 && !lisbonfpc_hello (self->fd, &stages, &error))
    {
      close (self->fd);
      self->fd = -1;
    }
  if (!error)
    {
      self->stages = stages;
      fpi_device_set_nr_enroll_stages (device, stages);
      self->watch = g_unix_fd_add (self->fd, G_IO_IN | G_IO_HUP | G_IO_ERR, lisbonfpc_readable, self);
    }
  fpi_device_open_complete (device, error);
}

static void
lisbonfpc_close (FpDevice *device)
{
  FpiDeviceLisbonFpc *self = FPI_DEVICE_LISBONFPC (device);

  g_clear_handle_id (&self->watch, g_source_remove);
  if (self->fd >= 0)
    close (self->fd);
  self->fd = -1;
  fpi_device_close_complete (device, NULL);
}

static void
lisbonfpc_enroll (FpDevice *device)
{
  FpiDeviceLisbonFpc *self = FPI_DEVICE_LISBONFPC (device);

  self->stage = 0;
  self->remaining = 0;
  lisbonfpc_request (device, "ENROLL");
}

static void
lisbonfpc_match (FpDevice *device)
{
  /*
   * Nothing to compare with: no match, without asking the sensor. fprintd identifies before every enrolment to
   * find duplicates, also with an empty gallery; the HAL has no templates then and ends the request with an error,
   * which would abort the enrolment.
   */
  if (fpi_device_get_current_action (device) == FPI_DEVICE_ACTION_IDENTIFY)
    {
      GPtrArray *gallery = NULL;

      fpi_device_get_identify_data (device, &gallery);
      if (!gallery || gallery->len == 0)
        {
          fpi_device_identify_report (device, NULL, NULL, NULL);
          fpi_device_identify_complete (device, NULL);
          return;
        }
    }

  lisbonfpc_request (device, "IDENTIFY");
}

static void
lisbonfpc_list (FpDevice *device)
{
  lisbonfpc_request (device, "LIST");
}

static void
lisbonfpc_delete (FpDevice *device)
{
  FpPrint *print = NULL;
  guint32 fid;
  g_autofree gchar *msg = NULL;

  fpi_device_get_delete_data (device, &print);
  fid = lisbonfpc_print_fid (print);
  if (!fid)
    {
      fpi_device_delete_complete (device, fpi_device_error_new (FP_DEVICE_ERROR_DATA_INVALID));
      return;
    }
  msg = g_strdup_printf ("DELETE %u", fid);
  lisbonfpc_request (device, msg);
}

static void
lisbonfpc_clear_storage (FpDevice *device)
{
  lisbonfpc_request (device, "DELETE 0");
}

static void
lisbonfpc_cancel (FpDevice *device)
{
  FpiDeviceLisbonFpc *self = FPI_DEVICE_LISBONFPC (device);

  /* the running ENROLL/IDENTIFY then ends with ERR canceled */
  if (self->fd >= 0)
    send (self->fd, "CANCEL", 6, MSG_NOSIGNAL);
}

/*
 * System sleep does not interrupt a running operation: the secure world keeps waiting for a finger and the kernel
 * driver of the sensor wakes the system on a touch while an identification runs. The operation continues after
 * resume, so a lock screen that waits for a finger can be woken and unlocked with one touch.
 */
static void
lisbonfpc_suspend (FpDevice *device)
{
  fpi_device_suspend_complete (device, NULL);
}

static void
lisbonfpc_resume (FpDevice *device)
{
  fpi_device_resume_complete (device, NULL);
}

static void
fpi_device_lisbonfpc_init (FpiDeviceLisbonFpc *self)
{
  self->fd = -1;
  self->stages = LISBONFPC_DEFAULT_STAGES;
}

static void
fpi_device_lisbonfpc_class_init (FpiDeviceLisbonFpcClass *klass)
{
  FpDeviceClass *dev_class = FP_DEVICE_CLASS (klass);

  dev_class->id = FP_COMPONENT;
  dev_class->full_name = "Moto G60s FPC sensor (TEE)";
  dev_class->type = FP_DEVICE_TYPE_VIRTUAL;
  dev_class->id_table = id_table;
  dev_class->scan_type = FP_SCAN_TYPE_PRESS;
  dev_class->nr_enroll_stages = LISBONFPC_DEFAULT_STAGES;
  dev_class->temp_hot_seconds = -1;

  dev_class->probe = lisbonfpc_probe;
  dev_class->open = lisbonfpc_open;
  dev_class->close = lisbonfpc_close;
  dev_class->enroll = lisbonfpc_enroll;
  dev_class->verify = lisbonfpc_match;
  dev_class->identify = lisbonfpc_match;
  dev_class->list = lisbonfpc_list;
  dev_class->delete = lisbonfpc_delete;
  dev_class->clear_storage = lisbonfpc_clear_storage;
  dev_class->cancel = lisbonfpc_cancel;
  dev_class->suspend = lisbonfpc_suspend;
  dev_class->resume = lisbonfpc_resume;

  fpi_device_class_auto_initialize_features (dev_class);
}
