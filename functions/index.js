const functions = require("firebase-functions");
const admin = require("firebase-admin");
admin.initializeApp();

const db = admin.firestore();

function eventsRef(familyId) {
  return db.collection("families").doc(familyId).collection("events");
}

async function addEvent(familyId, type) {
  const ref = eventsRef(familyId);
  const now = admin.firestore.Timestamp.now();
  const doc = await ref.add({ type, timestamp: now, createdBy: "voice" });

  if (type === "sleep_end" || type === "feed_end") {
    const startType = type === "sleep_end" ? "sleep_start" : "feed_start";
    const startSnap = await ref
      .where("type", "==", startType)
      .orderBy("timestamp", "desc")
      .limit(1)
      .get();
    if (!startSnap.empty) {
      const startDoc = startSnap.docs[0];
      if (!startDoc.data().linkedEventId) {
        await startDoc.ref.update({ linkedEventId: doc.id });
        await doc.update({ linkedEventId: startDoc.id });
      }
    }
  }
  return doc.id;
}

async function getStatus(familyId) {
  const ref = eventsRef(familyId);
  const now = Date.now();

  async function lastOfType(type) {
    const snap = await ref
      .where("type", "==", type)
      .orderBy("timestamp", "desc")
      .limit(1)
      .get();
    return snap.empty ? null : snap.docs[0].data().timestamp.toDate();
  }

  const sleepStart = await lastOfType("sleep_start");
  const sleepEnd = await lastOfType("sleep_end");
  const feedStart = await lastOfType("feed_start");
  const feedEnd = await lastOfType("feed_end");
  const lastPee = await lastOfType("pee");
  const lastPoop = await lastOfType("poop");

  return { sleepStart, sleepEnd, feedStart, feedEnd, lastPee, lastPoop, now };
}

function formatDuration(ms) {
  const mins = Math.round(ms / 60000);
  if (mins < 60) return `${mins} minutes`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m > 0 ? `${h} hours and ${m} minutes` : `${h} hours`;
}

async function deleteLastEvent(familyId) {
  const ref = eventsRef(familyId);
  const snap = await ref.orderBy("timestamp", "desc").limit(1).get();
  if (snap.empty) return "No events to undo.";
  const doc = snap.docs[0];
  const data = doc.data();
  if (data.linkedEventId) {
    await ref.doc(data.linkedEventId).update({
      linkedEventId: admin.firestore.FieldValue.delete(),
    });
  }
  await doc.ref.delete();
  return `Deleted the last event: ${data.type.replace("_", " ")}.`;
}

exports.dialogflowWebhook = functions.https.onRequest(async (req, res) => {
  try {
    const intent = req.body.queryResult?.intent?.displayName;
    const params = req.body.queryResult?.parameters || {};
    const familyId = params.familyId || "mello-ackerman";
    let speech = "Sorry, I didn't understand that.";

    switch (intent) {
      case "log.sleep.start":
        await addEvent(familyId, "sleep_start");
        speech = "Got it, Yuli went to sleep.";
        break;
      case "log.sleep.end":
        await addEvent(familyId, "sleep_end");
        speech = "Got it, Yuli woke up.";
        break;
      case "log.feed.start":
        await addEvent(familyId, "feed_start");
        speech = "Got it, Yuli started eating.";
        break;
      case "log.feed.end":
        await addEvent(familyId, "feed_end");
        speech = "Got it, Yuli finished eating.";
        break;
      case "log.pee":
        await addEvent(familyId, "pee");
        speech = "Logged a pee diaper for Yuli.";
        break;
      case "log.poop":
        await addEvent(familyId, "poop");
        speech = "Logged a poop diaper for Yuli.";
        break;
      case "query.sleep.status": {
        const s = await getStatus(familyId);
        if (s.sleepStart && (!s.sleepEnd || s.sleepStart > s.sleepEnd)) {
          speech = `Yuli has been sleeping for ${formatDuration(s.now - s.sleepStart.getTime())}.`;
        } else if (s.sleepEnd) {
          speech = `Yuli has been awake for ${formatDuration(s.now - s.sleepEnd.getTime())}.`;
        } else {
          speech = "I don't have any sleep data for Yuli yet.";
        }
        break;
      }
      case "query.feed.status": {
        const s = await getStatus(familyId);
        if (s.feedStart && (!s.feedEnd || s.feedStart > s.feedEnd)) {
          speech = `Yuli has been eating for ${formatDuration(s.now - s.feedStart.getTime())}.`;
        } else if (s.feedEnd) {
          speech = `Yuli's last feed ended ${formatDuration(s.now - s.feedEnd.getTime())} ago.`;
        } else {
          speech = "I don't have any feeding data for Yuli yet.";
        }
        break;
      }
      case "query.diaper.status": {
        const s = await getStatus(familyId);
        const parts = [];
        if (s.lastPee)
          parts.push(`last pee was ${formatDuration(s.now - s.lastPee.getTime())} ago`);
        if (s.lastPoop)
          parts.push(`last poop was ${formatDuration(s.now - s.lastPoop.getTime())} ago`);
        speech = parts.length > 0 ? "Yuli's " + parts.join(", and ") + "." : "No diaper data for Yuli yet.";
        break;
      }
      case "undo.last":
        speech = await deleteLastEvent(familyId);
        break;
    }

    res.json({ fulfillmentText: speech });
  } catch (err) {
    console.error("Webhook error:", err);
    res.json({ fulfillmentText: "Something went wrong, please try again." });
  }
});

exports.babyApi = functions.https.onRequest(async (req, res) => {
  // CORS for voice pages
  res.set("Access-Control-Allow-Origin", "*");
  res.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  res.set("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") { res.status(204).send(""); return; }

  const familyId = req.query.family || "mello-ackerman";
  const action = req.query.action;
  const voice = req.query.voice;

  try {
    // ===== VOICE ACTIONS (v2 data model) =====
    if (voice) {
      const ref = eventsRef(familyId);
      const now = admin.firestore.Timestamp.now();
      let message = "";

      switch (voice) {
        case "poop":
          await ref.add({ type: "diaper", startTime: now, pee: false, poop: true, createdBy: "voice", createdAt: now });
          message = "💩 Poop logged!";
          break;
        case "pee":
          await ref.add({ type: "diaper", startTime: now, pee: true, poop: false, createdBy: "voice", createdAt: now });
          message = "💧 Pee logged!";
          break;
        case "peepoop":
          await ref.add({ type: "diaper", startTime: now, pee: true, poop: true, createdBy: "voice", createdAt: now });
          message = "🧷 Pee + Poop logged!";
          break;
        case "startfeed":
          await ref.add({ type: "feed", startTime: now, pee: false, poop: false, createdBy: "voice", createdAt: now });
          message = "🍼 Feed started!";
          break;
        case "startfeedleft":
          await ref.add({ type: "feed", startTime: now, side: "left", pee: false, poop: false, createdBy: "voice", createdAt: now });
          message = "🤱 Feed started (left)!";
          break;
        case "startfeedright":
          await ref.add({ type: "feed", startTime: now, side: "right", pee: false, poop: false, createdBy: "voice", createdAt: now });
          message = "🤱 Feed started (right)!";
          break;
        case "endfeed": {
          const feedSnap = await ref.where("type", "==", "feed").orderBy("startTime", "desc").limit(1).get();
          if (!feedSnap.empty) {
            const feedDoc = feedSnap.docs[0];
            const feedData = feedDoc.data();
            if (!feedData.duration && !feedData.endTime) {
              const startMs = feedData.startTime.toMillis();
              const dur = Math.round((Date.now() - startMs) / 60000);
              await feedDoc.ref.update({ endTime: now, duration: dur });
              message = "⏹️ Feed ended (" + dur + "m)!";
            } else {
              message = "No ongoing feed to end.";
            }
          } else {
            message = "No feed found.";
          }
          break;
        }
        case "startsleep":
          await ref.add({ type: "sleep", startTime: now, pee: false, poop: false, createdBy: "voice", createdAt: now });
          message = "😴 Sleep started!";
          break;
        case "endsleep": {
          const sleepSnap = await ref.where("type", "==", "sleep").orderBy("startTime", "desc").limit(1).get();
          if (!sleepSnap.empty) {
            const sleepDoc = sleepSnap.docs[0];
            const sleepData = sleepDoc.data();
            if (!sleepData.duration && !sleepData.endTime) {
              const startMs = sleepData.startTime.toMillis();
              const dur = Math.round((Date.now() - startMs) / 60000);
              await sleepDoc.ref.update({ endTime: now, duration: dur });
              message = "⏰ Woke up (" + dur + "m)!";
            } else {
              message = "No ongoing sleep to end.";
            }
          } else {
            message = "No sleep found.";
          }
          break;
        }
        default:
          return res.status(400).json({ error: "Unknown voice action: " + voice });
      }
      return res.json({ message });
    }

    // ===== LEGACY API (v1 data model) =====
    if (req.method === "POST" || action) {
      const type = req.body?.type || action;
      if (!type) {
        return res.status(400).json({ error: "Missing 'type' or 'action' param" });
      }

      if (type === "undo") {
        const msg = await deleteLastEvent(familyId);
        return res.json({ message: msg });
      }

      const validTypes = [
        "sleep_start", "sleep_end",
        "feed_start", "feed_end",
        "pee", "poop",
      ];
      if (!validTypes.includes(type)) {
        return res.status(400).json({ error: `Invalid type: ${type}` });
      }

      const id = await addEvent(familyId, type);
      return res.json({ message: `Logged ${type}`, eventId: id });
    }

    const s = await getStatus(familyId);
    const speech = [];

    if (s.sleepStart && (!s.sleepEnd || s.sleepStart > s.sleepEnd)) {
      speech.push(`Yuli has been sleeping for ${formatDuration(s.now - s.sleepStart.getTime())}`);
    } else if (s.sleepEnd) {
      speech.push(`Yuli has been awake for ${formatDuration(s.now - s.sleepEnd.getTime())}`);
    }

    if (s.feedStart && (!s.feedEnd || s.feedStart > s.feedEnd)) {
      speech.push(`Feeding for ${formatDuration(s.now - s.feedStart.getTime())}`);
    } else if (s.feedEnd) {
      speech.push(`Yuli's last feed was ${formatDuration(s.now - s.feedEnd.getTime())} ago`);
    }

    if (s.lastPee) speech.push(`Last pee ${formatDuration(s.now - s.lastPee.getTime())} ago`);
    if (s.lastPoop) speech.push(`Last poop ${formatDuration(s.now - s.lastPoop.getTime())} ago`);

    return res.json({
      ...s,
      speech: speech.join(". ") || "No data yet.",
    });
  } catch (err) {
    console.error("API error:", err);
    return res.status(500).json({ error: err.message });
  }
});
