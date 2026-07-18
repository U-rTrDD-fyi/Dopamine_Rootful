/*
 * Minimal <bsm/libbsm.h> for Dopamine_Rootful.
 *
 * The iOS SDK does not ship libbsm.h, and the previously bundled copy of this
 * file was actually a truncated copy of <bsm/audit.h> (same _BSM_AUDIT_H guard,
 * cut off before the audit_token_to_* prototypes), so it declared none of the
 * functions the jailbreak code relies on and silently collided with the SDK's
 * own <bsm/audit.h>.
 *
 * This replacement provides just the audit_token_to_* prototypes actually used
 * by the project, with the real libbsm.h include guard (_LIBBSM_H_) so it never
 * shadows or is shadowed by <bsm/audit.h>. The functions are provided at link
 * time by libbsm (-lbsm) on device.
 */

#ifndef _LIBBSM_H_
#define _LIBBSM_H_

#include <sys/types.h>      /* uid_t, gid_t, pid_t */
#include <mach/message.h>   /* audit_token_t */
#include <sys/cdefs.h>      /* __BEGIN_DECLS / __END_DECLS */

__BEGIN_DECLS

uid_t audit_token_to_auid(audit_token_t atoken);
uid_t audit_token_to_euid(audit_token_t atoken);
gid_t audit_token_to_egid(audit_token_t atoken);
uid_t audit_token_to_ruid(audit_token_t atoken);
gid_t audit_token_to_rgid(audit_token_t atoken);
pid_t audit_token_to_pid(audit_token_t atoken);
int   audit_token_to_pidversion(audit_token_t atoken);

__END_DECLS

#endif /* _LIBBSM_H_ */
