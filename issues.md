# Issues

## Victorian GTFS-RT metro bus auth failure

### Status
- Static Victorian GTFS download/import works.
- Favourite Victorian bus stops work.
- Victorian dashboard bus card is wired and fetches scheduled departures from the local GTFS database.
- Realtime overlay is blocked by authentication failure against the Transport Victoria GTFS-RT metro bus feed.

### Current symptom
- Console output shows the request is reaching the correct endpoint but is rejected with `HTTP 401`.
- The server response body is:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<env:Envelope xmlns:env="http://www.w3.org/2003/05/soap-envelope">
   <env:Header>
   </env:Header>
   <env:Body>
      <env:Fault>
         <env:Code>
            <env:Value>env:Receiver
            </env:Value>
            <env:Subcode>
               <env:Value xmlns:fault="http://www.vordel.com/soapfaults">fault:MessageBlocked
               </env:Value>
            </env:Subcode>
         </env:Code>
         <env:Reason>
         </env:Reason>
         <env:Detail xmlns:fault="http://www.vordel.com/soapfaults" fault:type="faultDetails">
         </env:Detail>
      </env:Fault>
   </env:Body>
</env:Envelope>
```

### What has been verified
- The app is definitely reading and sending a stored Victorian realtime key.
- Runtime log example:

```text
ℹ️ Victorian GTFS-RT TripUpdates using key fingerprint eyJ0…O3nY (length: 175)
⚠️ Victorian GTFS-RT TripUpdates request failed with HTTP 401. Check that the configured key is a valid Transport Victoria Open Data subscription key for the GTFS-RT bus feed.
```

- The app currently sends the key in all of these forms:
  - `Ocp-Apim-Subscription-Key` HTTP header
  - `KeyID` HTTP header
  - `subscription-key` query parameter
- So this is no longer believed to be a header-name or request-shape problem.

### Strong current hypothesis
- The value stored in Settings is the wrong credential type for this feed.
- The observed fingerprint (`eyJ0…O3nY`, length `175`) does not match the UUID-style Open Data key we expected.
- The app may be storing:
  - a token copied from a different API/product
  - a JWT-like credential
  - or a stale/invalid value pasted into the Victorian realtime key field

### Relevant code
- Realtime request construction:
  - `/Users/fernandodeleon/dev/IOSDevelopment/myLatest/myLatest/Services/VictorianBusService.swift`
- Victorian static GTFS database:
  - `/Users/fernandodeleon/dev/IOSDevelopment/myLatest/myLatest/Services/VictorianBusGTFSDatabase.swift`
- Victorian bus settings field:
  - `/Users/fernandodeleon/dev/IOSDevelopment/myLatest/myLatest/Views/Dashboard/SettingsView.swift`

### Next investigation steps
1. Confirm exactly what credential Transport Victoria expects for the GTFS-RT metro bus feed:
   - Open Data subscription key
   - `KeyID`
   - product-specific API key
   - or some other account token
2. Compare the value shown in the app’s `Realtime API Key` field with the actual key generated in the Transport Victoria Open Data profile.
3. Retest using the expected UUID-style key and confirm the runtime fingerprint changes accordingly.
4. If auth succeeds, validate that realtime trip updates match local Victorian GTFS `trip_id` / `stop_id` values and actually produce `Pred`, `Late`, `Early`, or `On Time` states.
5. If auth continues to fail with the correct key, verify whether the GTFS-RT bus product must be explicitly subscribed to or enabled in the Transport Victoria portal.

### Follow-up product decision
- Even if realtime auth is fixed, the current on-device Victorian GTFS import takes roughly 5-10 minutes.
- Production direction should likely be:
  - build a precomputed Victorian bus SQLite DB on Mac
  - ship or download that DB directly
  - keep GTFS-RT as the live overlay on top of the prebuilt static store
