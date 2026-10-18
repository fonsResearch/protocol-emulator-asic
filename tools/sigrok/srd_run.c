/* Minimal libsigrokdecode front end (no libsigrok): feeds logic samples from a run-length
   file to a decoder stack and prints annotations.
   Usage: srd_run <samplerate_hz> <samples.rle> -d <id> [-o key=val]... [-c name=idx]...
                  [-s -d <id> [-o ...]]...
   -s stacks the next decoder on the previous one. samples.rle: one "count bitmask" pair per
   line (bit i = channel i, unitsize 1 byte). Output: "<decoder> <start> <end> <class> <text>"
   per annotation (first, longest text). Exit 0 on success. */
#include <libsigrokdecode/libsigrokdecode.h>
#include <glib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void on_ann(struct srd_proto_data *p, void *cb) {
  (void)cb;
  struct srd_proto_data_annotation *a = p->data;
  printf("%s %llu %llu %d %s\n", p->pdo->di->decoder->id, (unsigned long long)p->start_sample,
         (unsigned long long)p->end_sample, a->ann_class, a->ann_text[0]);
}

static GVariant *parse_val(const char *v) {
  char *end;
  long long x = strtoll(v, &end, 10);
  if (*v && *end == 0) return g_variant_new_int64(x);
  double d = strtod(v, &end);
  if (*v && *end == 0) return g_variant_new_double(d);
  return g_variant_new_string(v);
}

#define MAXD 4
int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage, see source\n"); return 2; }
  uint64_t rate = strtoull(argv[1], NULL, 10);
  const char *in = argv[2];
  const char *ids[MAXD]; GHashTable *opts[MAXD], *chans[MAXD]; int nd = 0;
  for (int i = 3; i < argc; i++) {
    if (!strcmp(argv[i], "-d") && i + 1 < argc) {
      if (nd == MAXD) return 2;
      ids[nd] = argv[++i];
      opts[nd] = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_variant_unref);
      chans[nd] = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, (GDestroyNotify)g_variant_unref);
      nd++;
    } else if ((!strcmp(argv[i], "-o") || !strcmp(argv[i], "-c")) && i + 1 < argc && nd > 0) {
      char *kv = g_strdup(argv[++i]); char *eq = strchr(kv, '=');
      if (!eq) return 2;
      *eq = 0;
      if (argv[i - 1][1] == 'o')
        g_hash_table_insert(opts[nd - 1], g_strdup(kv), g_variant_ref_sink(parse_val(eq + 1)));
      else
        g_hash_table_insert(chans[nd - 1], g_strdup(kv), g_variant_ref_sink(g_variant_new_int32(atoi(eq + 1))));
      g_free(kv);
    } else if (!strcmp(argv[i], "-s")) {
      /* stacking is implied: every decoder after the first is stacked on its predecessor */
    } else { fprintf(stderr, "bad arg %s\n", argv[i]); return 2; }
  }
  if (srd_init(NULL) != SRD_OK) { fprintf(stderr, "srd_init failed\n"); return 1; }
  struct srd_session *s;
  srd_session_new(&s);
  struct srd_decoder_inst *di[MAXD];
  for (int k = 0; k < nd; k++) {
    if (srd_decoder_load(ids[k]) != SRD_OK) { fprintf(stderr, "load %s failed\n", ids[k]); return 1; }
    di[k] = srd_inst_new(s, ids[k], opts[k]);
    if (!di[k]) { fprintf(stderr, "inst %s failed\n", ids[k]); return 1; }
    if (g_hash_table_size(chans[k]) && srd_inst_channel_set_all(di[k], chans[k]) != SRD_OK) {
      fprintf(stderr, "channels %s failed\n", ids[k]); return 1; }
    if (k > 0 && srd_inst_stack(s, di[k - 1], di[k]) != SRD_OK) { fprintf(stderr, "stack failed\n"); return 1; }
  }
  srd_pd_output_callback_add(s, SRD_OUTPUT_ANN, on_ann, NULL);
  srd_session_metadata_set(s, SRD_CONF_SAMPLERATE, g_variant_new_uint64(rate));
  if (srd_session_start(s) != SRD_OK) { fprintf(stderr, "start failed\n"); return 1; }
  FILE *f = fopen(in, "r");
  if (!f) { perror(in); return 1; }
  enum { CH = 1 << 16 };
  uint8_t *buf = malloc(CH); uint64_t fill = 0, pos = 0;
  unsigned long long cnt; unsigned v;
  while (fscanf(f, "%llu %u", &cnt, &v) == 2) {
    for (unsigned long long r = 0; r < cnt; r++) {
      buf[fill++] = (uint8_t)v;
      if (fill == CH) {
        if (srd_session_send(s, pos, pos + fill, buf, fill, 1) != SRD_OK) { fprintf(stderr, "send failed\n"); return 1; }
        pos += fill; fill = 0;
      }
    }
  }
  if (fill && srd_session_send(s, pos, pos + fill, buf, fill, 1) != SRD_OK) { fprintf(stderr, "send failed\n"); return 1; }
  fclose(f);
  srd_session_destroy(s);
  srd_exit();
  return 0;
}
