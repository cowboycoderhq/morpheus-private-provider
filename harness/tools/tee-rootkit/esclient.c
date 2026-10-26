// esclient: tries to become an Endpoint Security client (A-4). Ad-hoc signed
// with the ES entitlement; AMFI is expected to refuse it.
#include <EndpointSecurity/EndpointSecurity.h>
#include <stdio.h>
int main(void) {
  es_client_t *c = NULL;
  es_new_client_result_t r = es_new_client(&c, ^(es_client_t *cl, const es_message_t *m) { (void)cl; (void)m; });
  printf("es_new_client result=%d (0 = client created)\n", (int)r);
  if (r == ES_NEW_CLIENT_RESULT_SUCCESS) es_delete_client(c);
  return r == ES_NEW_CLIENT_RESULT_SUCCESS ? 0 : 1;
}
