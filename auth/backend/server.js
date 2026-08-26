/**
 * Stand-in for FhirSpark.
 *
 * It is deliberately not FhirSpark: the question under test is whether an
 * injected bundle can reach an authenticated backend through the
 * OpenResty/Keycloak layer without doing any token handling of its own, and
 * that question is answered entirely by the proxy. FhirSpark itself never sees
 * OIDC -- it receives requests the proxy has already authenticated and trusts
 * the X-USERLOGIN / X-USERROLES headers it injects.
 *
 * So this service does what FhirSpark does with respect to auth -- read the
 * injected headers, refuse writes without them -- and reports back exactly what
 * it saw, which is what makes the test legible.
 */
const http = require('http');

const PORT = 3001;

/** patientId -> recommendations */
const store = new Map();

function identityOf(req) {
    const cookies = req.headers.cookie || '';
    return {
        // Injected by the proxy after it validates the Keycloak session.
        // The bundle never sends these.
        login: req.headers['x-userlogin'] || null,
        name: req.headers['x-username'] || null,
        roles: req.headers['x-userroles'] || null,
        // Evidence that the browser attached cBioPortal's own session cookie
        // to this request too, without the bundle asking it to.
        sawCbioportalSession: /(^|;\s*)JSESSIONID=/.test(cookies),
        sawProxySession: /(^|;\s*)session(_\d+)?=/.test(cookies),
    };
}

function send(res, status, body) {
    const payload = JSON.stringify(body, null, 2);
    res.writeHead(status, {
        'Content-Type': 'application/json',
        'Cache-Control': 'no-store',
    });
    res.end(payload);
}

function readBody(req) {
    return new Promise(resolve => {
        let data = '';
        req.on('data', c => (data += c));
        req.on('end', () => {
            try {
                resolve(data ? JSON.parse(data) : {});
            } catch {
                resolve({});
            }
        });
    });
}

const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    const patientId = decodeURIComponent(
        url.pathname.replace(/^\/mtb\/?/, '').split('/')[0] || ''
    );
    const identity = identityOf(req);

    if (req.method === 'GET') {
        // Reads are unauthenticated, matching the proxy config, so identity is
        // normally null here. Reported anyway so the difference is visible.
        return send(res, 200, {
            patientId,
            recommendations: store.get(patientId) || [],
            identity,
        });
    }

    if (req.method === 'PUT' || req.method === 'POST') {
        // Belt and braces: the proxy already refused unauthenticated writes.
        // A backend that trusts injected headers must still verify they are
        // present, or it is trivially bypassed if it is ever exposed directly.
        if (!identity.login || identity.login === 'unknown') {
            return send(res, 401, {
                error: 'not_authenticated',
                detail: 'no X-USERLOGIN injected by the proxy',
                identity,
            });
        }

        const body = await readBody(req);
        const entry = {
            id: `rec-${Date.now()}`,
            patientId,
            title: body.title || 'Untitled recommendation',
            author: identity.login,
            authorName: identity.name,
            createdAt: new Date().toISOString(),
        };
        store.set(patientId, [...(store.get(patientId) || []), entry]);

        return send(res, 200, { saved: entry, identity });
    }

    send(res, 405, { error: 'method_not_allowed' });
});

server.listen(PORT, () => console.log(`mtb-backend listening on ${PORT}`));
