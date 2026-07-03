// SPDX-License-Identifier: MIT
/*
 * Drive GStreamer events that gst-launch-1.0 cannot issue on demand.
 *
 * The conformance suite uses this helper to trigger flush/seek handling after
 * a Rockchip MPP element has produced data, then requires post-event output so
 * reset/recovery paths are exercised rather than only accepting the event.
 */

#include <gst/gst.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

enum harness_action {
	ACTION_FLUSH,
	ACTION_SEEK,
	ACTION_FLUSH_SEEK,
};

struct harness {
	GMainLoop *loop;
	GstElement *pipeline;
	GstElement *target;
	GstPad *target_src;
	enum harness_action action;
	guint trigger_buffers;
	guint post_buffers;
	guint seek_ms;
	guint timeout_ms;
	guint timeout_id;
	guint before_buffers;
	guint after_buffers;
	gboolean action_queued;
	gboolean action_done;
	gboolean success;
	gchar *failure;
};

static void usage(const char *argv0)
{
	g_printerr("Usage: %s --pipeline PIPELINE --target ELEMENT --action flush|seek|flush-seek [options]\n",
		   argv0);
	g_printerr("Options:\n");
	g_printerr("  --trigger-buffers N  buffers from target src before event (default: 1)\n");
	g_printerr("  --post-buffers N     buffers from target src after event (default: 1)\n");
	g_printerr("  --seek-ms N          seek target for seek actions (default: 0)\n");
	g_printerr("  --timeout-ms N       whole-test timeout (default: 30000)\n");
}

static const char *next_arg(int *i, int argc, char **argv)
{
	if (*i + 1 >= argc)
		return NULL;

	(*i)++;
	return argv[*i];
}

static gboolean parse_uint(const char *value, guint *out)
{
	char *end = NULL;
	unsigned long parsed;

	if (!value || !*value)
		return FALSE;

	parsed = strtoul(value, &end, 10);
	if (!end || *end)
		return FALSE;

	*out = (guint)parsed;
	return TRUE;
}

static void fail(struct harness *h, const char *format, ...)
{
	va_list args;

	if (h->success || h->failure)
		return;

	va_start(args, format);
	h->failure = g_strdup_vprintf(format, args);
	va_end(args);
	g_main_loop_quit(h->loop);
}

static void finish_success(struct harness *h)
{
	h->success = TRUE;
	g_main_loop_quit(h->loop);
}

static gboolean do_flush(struct harness *h)
{
	GstPad *sink;
	gboolean ok;

	sink = gst_element_get_static_pad(h->target, "sink");
	if (!sink) {
		fail(h, "target element has no sink pad");
		return FALSE;
	}

	ok = gst_pad_send_event(sink, gst_event_new_flush_start());
	if (ok)
		ok = gst_pad_send_event(sink, gst_event_new_flush_stop(TRUE));

	gst_object_unref(sink);
	if (!ok) {
		fail(h, "target flush event was rejected");
		return FALSE;
	}

	return TRUE;
}

static gboolean do_seek(struct harness *h)
{
	gint64 pos = (gint64)h->seek_ms * GST_MSECOND;

	if (!gst_element_seek_simple(h->pipeline, GST_FORMAT_TIME,
				     GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT,
				     pos)) {
		fail(h, "pipeline seek was rejected");
		return FALSE;
	}

	return TRUE;
}

static gboolean trigger_action(gpointer data)
{
	struct harness *h = data;

	if (h->action_done || h->failure)
		return G_SOURCE_REMOVE;

	switch (h->action) {
	case ACTION_FLUSH:
		if (!do_flush(h))
			return G_SOURCE_REMOVE;
		break;
	case ACTION_SEEK:
		if (!do_seek(h))
			return G_SOURCE_REMOVE;
		break;
	case ACTION_FLUSH_SEEK:
		if (!do_flush(h) || !do_seek(h))
			return G_SOURCE_REMOVE;
		break;
	}

	h->action_done = TRUE;
	g_print("event action completed after %u target buffers\n",
		h->before_buffers);

	if (!h->post_buffers)
		finish_success(h);

	return G_SOURCE_REMOVE;
}

static GstPadProbeReturn buffer_probe(GstPad *pad, GstPadProbeInfo *info,
				      gpointer data)
{
	struct harness *h = data;

	(void)pad;
	(void)info;

	if (h->failure || h->success)
		return GST_PAD_PROBE_OK;

	if (!h->action_done) {
		h->before_buffers++;
		if (h->before_buffers >= h->trigger_buffers && !h->action_queued) {
			h->action_queued = TRUE;
			g_main_context_invoke(NULL, trigger_action, h);
		}
		return GST_PAD_PROBE_OK;
	}

	h->after_buffers++;
	if (h->after_buffers >= h->post_buffers)
		finish_success(h);

	return GST_PAD_PROBE_OK;
}

static gboolean bus_cb(GstBus *bus, GstMessage *msg, gpointer data)
{
	struct harness *h = data;

	(void)bus;

	switch (GST_MESSAGE_TYPE(msg)) {
	case GST_MESSAGE_ERROR: {
		GError *err = NULL;
		gchar *debug = NULL;

		gst_message_parse_error(msg, &err, &debug);
		fail(h, "pipeline error from %s: %s%s%s",
		     GST_OBJECT_NAME(msg->src), err ? err->message : "unknown",
		     debug ? " debug=" : "", debug ? debug : "");
		g_clear_error(&err);
		g_free(debug);
		break;
	}
	case GST_MESSAGE_EOS:
		if (!h->action_done)
			fail(h, "pipeline reached EOS before event action");
		else
			fail(h, "pipeline reached EOS before %u post-event buffers",
			     h->post_buffers);
		break;
	default:
		break;
	}

	return G_SOURCE_CONTINUE;
}

static gboolean timeout_cb(gpointer data)
{
	struct harness *h = data;

	h->timeout_id = 0;
	fail(h, "timeout after %u ms; before=%u after=%u action_done=%d",
	     h->timeout_ms, h->before_buffers, h->after_buffers,
	     h->action_done);
	return G_SOURCE_REMOVE;
}

int main(int argc, char **argv)
{
	const char *pipeline_desc = NULL;
	const char *target_name = NULL;
	const char *action_name = NULL;
	GstBus *bus;
	GError *err = NULL;
	struct harness h = {
		.trigger_buffers = 1,
		.post_buffers = 1,
		.timeout_ms = 30000,
	};
	const char *bad_number_arg = NULL;
	int i;

	for (i = 1; i < argc; i++) {
		const char *arg = argv[i];
		const char *value = NULL;

		if (!strcmp(arg, "--pipeline"))
			pipeline_desc = next_arg(&i, argc, argv);
		else if (g_str_has_prefix(arg, "--pipeline="))
			pipeline_desc = arg + strlen("--pipeline=");
		else if (!strcmp(arg, "--target"))
			target_name = next_arg(&i, argc, argv);
		else if (g_str_has_prefix(arg, "--target="))
			target_name = arg + strlen("--target=");
		else if (!strcmp(arg, "--action"))
			action_name = next_arg(&i, argc, argv);
		else if (g_str_has_prefix(arg, "--action="))
			action_name = arg + strlen("--action=");
		else if (!strcmp(arg, "--trigger-buffers"))
			value = next_arg(&i, argc, argv);
		else if (g_str_has_prefix(arg, "--trigger-buffers="))
			value = arg + strlen("--trigger-buffers=");
		else if (!strcmp(arg, "--post-buffers"))
			value = next_arg(&i, argc, argv);
		else if (g_str_has_prefix(arg, "--post-buffers="))
			value = arg + strlen("--post-buffers=");
		else if (!strcmp(arg, "--seek-ms"))
			value = next_arg(&i, argc, argv);
		else if (g_str_has_prefix(arg, "--seek-ms="))
			value = arg + strlen("--seek-ms=");
		else if (!strcmp(arg, "--timeout-ms"))
			value = next_arg(&i, argc, argv);
		else if (g_str_has_prefix(arg, "--timeout-ms="))
			value = arg + strlen("--timeout-ms=");
		else {
			usage(argv[0]);
			return 2;
		}

		if (!value)
			continue;

		if (g_str_has_prefix(arg, "--trigger-buffers")) {
			if (!parse_uint(value, &h.trigger_buffers)) {
				bad_number_arg = arg;
				goto bad_number;
			}
		} else if (g_str_has_prefix(arg, "--post-buffers")) {
			if (!parse_uint(value, &h.post_buffers)) {
				bad_number_arg = arg;
				goto bad_number;
			}
		} else if (g_str_has_prefix(arg, "--seek-ms")) {
			if (!parse_uint(value, &h.seek_ms)) {
				bad_number_arg = arg;
				goto bad_number;
			}
		} else if (g_str_has_prefix(arg, "--timeout-ms")) {
			if (!parse_uint(value, &h.timeout_ms)) {
				bad_number_arg = arg;
				goto bad_number;
			}
		}
	}

	if (!pipeline_desc || !target_name || !action_name) {
		usage(argv[0]);
		return 2;
	}

	if (!strcmp(action_name, "flush"))
		h.action = ACTION_FLUSH;
	else if (!strcmp(action_name, "seek"))
		h.action = ACTION_SEEK;
	else if (!strcmp(action_name, "flush-seek"))
		h.action = ACTION_FLUSH_SEEK;
	else {
		g_printerr("unknown action: %s\n", action_name);
		return 2;
	}

	gst_init(&argc, &argv);

	h.pipeline = gst_parse_launch(pipeline_desc, &err);
	if (!h.pipeline) {
		g_printerr("failed to parse pipeline: %s\n",
			   err ? err->message : "unknown");
		g_clear_error(&err);
		return 2;
	}

	h.target = gst_bin_get_by_name(GST_BIN(h.pipeline), target_name);
	if (!h.target) {
		g_printerr("pipeline has no element named %s\n", target_name);
		gst_object_unref(h.pipeline);
		return 2;
	}

	h.target_src = gst_element_get_static_pad(h.target, "src");
	if (!h.target_src) {
		g_printerr("target element has no src pad\n");
		gst_object_unref(h.target);
		gst_object_unref(h.pipeline);
		return 2;
	}

	h.loop = g_main_loop_new(NULL, FALSE);
	gst_pad_add_probe(h.target_src, GST_PAD_PROBE_TYPE_BUFFER, buffer_probe,
			  &h, NULL);

	bus = gst_element_get_bus(h.pipeline);
	gst_bus_add_watch(bus, bus_cb, &h);
	gst_object_unref(bus);

	if (gst_element_set_state(h.pipeline, GST_STATE_PLAYING) ==
	    GST_STATE_CHANGE_FAILURE) {
		g_printerr("failed to set pipeline to PLAYING\n");
		g_main_loop_unref(h.loop);
		gst_object_unref(h.target_src);
		gst_object_unref(h.target);
		gst_object_unref(h.pipeline);
		return 1;
	}

	h.timeout_id = g_timeout_add(h.timeout_ms, timeout_cb, &h);
	g_main_loop_run(h.loop);
	if (h.timeout_id)
		g_source_remove(h.timeout_id);

	gst_element_set_state(h.pipeline, GST_STATE_NULL);

	if (h.success) {
		g_print("PASS: before=%u after=%u action=%s\n",
			h.before_buffers, h.after_buffers, action_name);
	} else {
		g_printerr("FAIL: %s\n", h.failure ? h.failure : "unknown");
	}

	g_free(h.failure);
	g_main_loop_unref(h.loop);
	gst_object_unref(h.target_src);
	gst_object_unref(h.target);
	gst_object_unref(h.pipeline);

	return h.success ? 0 : 1;

bad_number:
	g_printerr("bad numeric value for %s\n",
		   bad_number_arg ? bad_number_arg : "option");
	return 2;
}
