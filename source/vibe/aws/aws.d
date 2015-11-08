/**
  Vibe-based AWS client
 */

module vibe.aws.aws;

import std.algorithm;
import std.datetime;
import std.random;
import std.range;
import std.stdio;
import std.string;

import vibe.core.core;
import vibe.core.log;
import vibe.data.json;
import vibe.http.client;
import vibe.inet.message;

import std.digest.sha;
import vibe.aws.sigv4;

public import vibe.aws.credentials;

class AWSException : Exception
{
    immutable string type;
    immutable bool retriable;

    this(string type, bool retriable, string message)
    {
        super(type ~ ": " ~ message);
        this.type = type;
        this.retriable = retriable;
    }

    /**
      Returns the 'ThrottlingException' from 'com.amazon.coral.service#ThrottlingException'
     */
    @property string simpleType() 
    {
        auto h = type.indexOf('#');
        if (h == -1) return type;
        return type[h+1..$];
    }
}

/**
  Configuraton for AWS clients
 */
struct ClientConfiguration
{
    uint maxErrorRetry = 3;
}

/**
  Thrown when the signature/authorization information is wrong
 */
class AuthorizationException : AWSException
{
    this(string type, string message)
    {
        super(type, false, message);
    }
}

struct ExponentialBackoff
{
    immutable uint maxRetries;
    uint tries = 0;
    uint maxSleepMs = 10;

    this(uint maxRetries)
    {
        this.maxRetries = maxRetries;
    }

    @property bool canRetry()
    {
        return tries < maxRetries;
    }

    @property bool finished()
    {
        return tries >= maxRetries + 1;
    }

    void inc()
    {
        tries++;
        maxSleepMs *= 2;
    }

    void sleep()
    {
        vibe.core.core.sleep(uniform!("[]")(1, maxSleepMs).msecs);
    }

    int opApply(scope int delegate(uint) attempt)
    {
        int result = 0;
        for (; !finished; inc())
        {
            try
            {
                result = attempt(maxRetries - tries);
                if (result)
                    return result;
            }
            catch (AWSException ex)
            {
                logWarn(ex.msg);
                // Retry if possible and retriable, otherwise give up.
                if (!canRetry || !ex.retriable) throw ex;
            }
            catch (Throwable t) //ssl errors from ssl.d
            {
                logWarn(typeid(t).name ~ " occurred at " ~ t.file ~ ":" ~ t.line.to!string ~ ":" ~ t.msg);
                if (!canRetry)
                    throw t;
            }
            sleep();
        }
        return result;
    }
}

class AWSClient {
    protected static immutable exceptionPrefix = "com.amazon.coral.service#";

    immutable string endpoint;
    immutable string region;
    immutable string service;

    private AWSCredentialSource m_credsSource;
    private ClientConfiguration m_config;

    this(string endpoint, string region, string service, AWSCredentialSource credsSource, ClientConfiguration config=ClientConfiguration()) 
    {
        this.region = region;
        this.endpoint = endpoint;
        this.service = service;
        this.m_credsSource = credsSource;
        this.m_config = config;
    }

    AWSResponse doRESTUpload(HTTPMethod method, string resource, in InetHeaderMap headers,
                             InputStream payload, ulong payloadSize, ulong blockSize = 512*1024
                            )
    {
        enforce(blockSize > 8*1024, "The block size for an upload has to be bigger than 8KB.");

        auto credScope = region ~ "/" ~ service;
        auto creds = m_credsSource.credentials(credScope);

        auto retries = ExponentialBackoff(m_config.maxErrorRetry);
        foreach(triesLeft; retries)
        {
            HTTPClientResponse resp;
            scope(failure) 
                if (resp)
                {
                    resp.dropBody();
                    resp.destroy();
                }

            if (!resource.startsWith("/"))
                resource = "/" ~ resource;

            resp = requestHTTP("https://" ~ endpoint ~ resource, (scope HTTPClientRequest req) {
                req.method = method;
                
                foreach(key, value; headers)
                    req.headers[key] = value;

                //Since we might be doing retries, update the date
                auto isoTimeString = currentTimeString();
                auto date = isoTimeString.dateFromISOString;
                auto time = isoTimeString.timeFromISOString;
                req.headers["x-amz-date"] = currentTimeString();

                string newEncoding = "aws-chunked";
                if ("Content-Encoding" in headers)
                    newEncoding ~= "," ~headers["Content-Encoding"];
                req.headers["Content-Encoding"] = newEncoding;
                req.headers["Transfer-Encoding"] = "chunked";
                req.headers["x-amz-content-sha256"] = "STREAMING-AWS4-HMAC-SHA256-PAYLOAD";
                req.headers["x-amz-decoded-content-length"] = payloadSize.to!string;
                req.headers["x-amz-decoded-content-length"] = payloadSize.to!string;

                if ("Content-Length" in headers)
                    req.headers.remove("Content-Length");

                if ("x-amz-storage-class" !in req.headers)
                        req.headers["x-amz-storage-class"] = "STANDARD";

                auto canonicalRequest = CanonicalRequest(
                        method.to!string,
                        resource,
                        null,
                        [
                            "host":                         req.headers["host"],
                            "content-encoding":             req.headers["Content-Encoding"],
                            "transfer-encoding":            req.headers["Transfer-Encoding"],
                            "x-amz-content-sha256":         req.headers["x-amz-content-sha256"],
                            "x-amz-date":                   req.headers["x-amz-date"],
                            "x-amz-decoded-content-length": req.headers["x-amz-decoded-content-length"],
                            "x-amz-storage-class":          req.headers["x-amz-storage-class"],
                        ],
                        null
                    );

                auto signableRequest = SignableRequest(date, time, region, service, canonicalRequest);
                auto credScope = date ~ "/" ~ region ~ "/" ~ service;
                auto key = signingKey(creds.accessKeySecret, date, region, service);
                auto binarySignature = key.sign(cast(ubyte[])signableRequest.signableStringForStream);

                auto authHeader = createSignatureHeader(creds.accessKeyID, credScope, canonicalRequest.headers, binarySignature);
                req.headers["authorization"] = authHeader;

                auto outputStream = cast(ChunkedOutputStream) req.bodyWriter;
                enforce(outputStream !is null);

                ubyte[] buffer = new ubyte[](blockSize);
                auto signature = binarySignature.toHexString().toLower();
                auto readChunk = (ulong numBytes) {
                        auto bytes = buffer[0..numBytes];
                        payload.read(bytes);
                        auto chunk = SignableChunk(date,time,region,service,signature,hash(bytes));
                        signature = key.sign(cast(ubyte[])chunk.signableString).toHexString().toLower();
                        outputStream.writeChunk(bytes,"chunk-signature="~signature);
                    };

                ulong bytesLeft = payloadSize;
                while(true)
                {
                    readChunk(bytesLeft);

                    if (bytesLeft < blockSize)
                            break;

                    bytesLeft -= blockSize;
                }
                readChunk(0);
            });
            //checkForError(resp);

            ubyte[] buffer = new ubyte[](1024);
            string b = "";
            auto reader = resp.bodyReader;
            while(!reader.empty)
            {
                auto size = reader.leastSize;
                if (buffer.length < size)
                    buffer = new ubyte[](size);

                reader.read(buffer[0..size]);
                b ~= cast(string)buffer[0..size];
            }

            return new AWSResponse(resp);
        }
        assert(0);
    }

    AWSResponse doRequest(string operation, Json request)
    {
        auto backoff = ExponentialBackoff(m_config.maxErrorRetry);

        for (; !backoff.finished; backoff.inc())
        {
            auto credScope = region ~ "/" ~ service;
            auto creds = m_credsSource.credentials(credScope);
            HTTPClientResponse resp;
            try
            {
                // FIXME: Auto-retries for retriable errors
                // FIXME: Report credential errors and retry for failed credentials
                 resp = requestHTTP("https://" ~ endpoint ~ "/", (scope req) {
                    auto timeString = currentTimeString();
                    auto jsonString = cast(ubyte[])request.toString();

                    req.method = HTTPMethod.POST;
                    req.headers["x-amz-target"] = operation;
                    req.headers["x-amz-date"] = currentTimeString();
                    req.headers["host"] = endpoint;
                    if (creds.sessionToken && !creds.sessionToken.empty)
                        req.headers["x-amz-security-token"] = creds.sessionToken;
                    req.contentType = "application/x-amz-json-1.1";
                    signRequest(req, jsonString, creds, timeString, region, service);
                    req.writeBody(jsonString);
                });

                checkForError(resp);

                return new AWSResponse(resp);
            }
            catch (AuthorizationException ex)
            {
                logWarn(ex.msg);
                // Report credentials as invalid. Will retry if possible.
                m_credsSource.credentialsInvalid(credScope, creds, ex.msg);
                resp.dropBody();
                resp.destroy();
                if (!backoff.canRetry) throw ex;
            }
            catch (AWSException ex)
            {
                logWarn(ex.msg);
                resp.dropBody();
                resp.destroy();
                // Retry if possible and retriable, otherwise give up.
                if (!backoff.canRetry || !ex.retriable) throw ex;
            } 
            catch (Throwable t) //ssl errors from ssl.d
            {
              if (!backoff.canRetry)
              {
                logError("no retries left, failing request");
                throw(t);
              }
            }
            backoff.sleep();
        }
        assert(0);
    }

    protected auto currentTimeString()
    {
        auto t = Clock.currTime(UTC());
        t.fracSec = FracSec.zero();
        return t.toISOString();
    }

    void checkForError(HTTPClientResponse response)
    {
        if (response.statusCode < 400) return; // No error

        auto bod = response.readJson();

        throw makeException(bod.__type.get!string, response.statusCode / 100 == 5, bod.message.opt!string(""));
    }
    
    AWSException makeException(string type, bool retriable, string message)
    {
        if (type == exceptionPrefix ~ "UnrecognizedClientException" || type == exceptionPrefix ~ "InvalidSignatureException")
            throw new AuthorizationException(type, message);
        return new AWSException(type, retriable, message);
    }
}

private void signRequest(HTTPClientRequest req, ubyte[] requestBody, AWSCredentials creds, string timeString, string region, string service)
{
    auto dateString = dateFromISOString(timeString);
    auto credScope = dateString ~ "/" ~ region ~ "/" ~ service;

    SignableRequest signRequest;
    signRequest.dateString = dateString;
    signRequest.timeStringUTC = timeFromISOString(timeString);
    signRequest.region = region;
    signRequest.service = service;
    signRequest.canonicalRequest.method = req.method.to!string();
    signRequest.canonicalRequest.uri = req.requestURL; // FIXME: Can include query params
    auto reqHeaders = req.headers.toRepresentation;
    foreach (x; reqHeaders) {
        signRequest.canonicalRequest.headers[x.key] = x.value;
    }
    signRequest.canonicalRequest.payload = requestBody;

    ubyte[] signKey = signingKey(creds.accessKeySecret, dateString, region, service);
    ubyte[] stringToSign = cast(ubyte[])signableString(signRequest);
    auto signature = sign(signKey, stringToSign);

    auto authHeader = createSignatureHeader(creds.accessKeyID, credScope, signRequest.canonicalRequest.headers, signature);
    req.headers["authorization"] = authHeader;
}

class AWSResponse
{
  
    private Json m_body;

    this(HTTPClientResponse response)
    {
        //m_response = response;
        m_body = response.readJson();
        response.dropBody();
        response.destroy();
    }
    
    override string toString()
    {
      return m_body.toString();
    }

    @property Json responseBody() { return m_body; }
}
