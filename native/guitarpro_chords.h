#pragma once

namespace guitarpro {
inline QJsonObject semanticChord(const gp::core::Staff &staff, const QString &id) {
    if (id.isEmpty()) return {};
    using namespace gp::core::chord;
    const gp::core::chord::Chord *chord = nullptr; const Diagram *diagram = nullptr; QString name;
    if (const auto item = staff.diagramCollection().find(id)) {
        const auto &entry = item->entry(); chord = entry.chord(); diagram = &entry.diagram(); name = entry.name();
    } else if (const auto item = staff.chordCollection().find(id)) {
        const auto &entry = item->entry(); chord = entry.chord(); name = entry.name();
    } else throw std::runtime_error("Beat references a missing native chord entry");
    QJsonObject result{{"name", name}};
    if (chord) {
        QJsonArray degrees;
        for (const auto &degree : chord->degrees()) degrees.append(QJsonObject{
            {"value", gp::core::Interval::valueToString(degree.value)},
            {"alteration", gp::core::Interval::alterationToString(degree.alteration)}, {"omitted", degree.omitted}});
        const int type = int(chord->type());
        result["root"] = chord->keyNote().toString(); result["bass"] = chord->bass().toString();
        result["type"] = type; result["type_name"] = type >= 0 && type <= 28 ? Chord::chordTypeToString(chord->type()) : QString();
        result["inversion"] = int(chord->inversion()); result["degrees"] = degrees;
    }
    if (diagram) {
        QJsonArray frets, fingers, barres;
        const auto strings = diagram->gp::core::chord::Diagram::stringCount();
        semanticRequire(strings <= 12 && diagram->fretCount() <= 36, "Native diagram exceeds the supported size");
        for (unsigned s = 0; s < strings; ++s) {
            const unsigned fret = diagram->fret(s, static_cast<Diagram::FretValueType>(0));
            frets.append(fret == ~0u ? -1 : int(fret));
            if (const auto fingering = diagram->fingering()) for (unsigned f = 0; f <= diagram->fretCount(); ++f) {
                const int finger = int(fingering->finger(s, f));
                if (finger >= 0) fingers.append(QJsonObject{{"string", int(s)}, {"fret", int(f)}, {"finger", finger}});
            }
        }
        // GP persists barres through repeated finger positions at one fret.
        // FreeDiagram's decorative barres are not serialized by chord::Diagram.
        if (const auto fingering = diagram->fingering()) for (unsigned f = 1; f <= diagram->fretCount(); ++f) if (fingering->bar(int(f))) {
            int from = -1, to = -1, finger = -1;
            for (unsigned s = 0; s < strings; ++s) {
                const int value = int(fingering->finger(s, f));
                if (value < 0) continue;
                if (from < 0) { from = int(s); finger = value; }
                if (value == finger) to = int(s);
            }
            if (to > from) barres.append(QJsonObject{{"from_string", from}, {"to_string", to}, {"fret", int(f)}, {"finger", finger}});
        }
        result["diagram"] = QJsonObject{{"first_fret", int(diagram->baseFret()) + 1}, {"fret_count", int(diagram->fretCount())}, {"frets", frets}, {"barres", barres}, {"fingers", fingers}};
    }
    return result;
}
inline void semanticSetChord(gp::core::Score *score, const gp::core::ScoreModelRange &range, const QJsonObject &spec, int strings) {
    using namespace gp::core;
    semanticKeys(spec, {"name", "root", "bass", "type", "type_name", "inversion", "degrees", "diagram"});
    const auto pitch = [&](const QJsonValue &value) {
        const QString text = semanticText(value, 4);
        semanticRequire(QRegularExpression("^[A-G](?:#|b|##|bb)?$").match(text).hasMatch(), "Chord pitch must be A..G with optional accidentals");
        return PitchClass::fromString(text);
    };
    const auto root = pitch(spec.value("root")), bass = pitch(semanticDefault(spec, "bass", spec.value("root")));
    const int type = semanticInt(semanticDefault(spec, "type", 0), -1, 28, "chord.type");
    chord::Chord chord(root, bass, static_cast<chord::Chord::Type>(type < 0 ? 0 : type));
    if (spec.contains("degrees")) {
        semanticRequire(spec.value("degrees").isArray() && spec.value("degrees").toArray().size() <= 16, "degrees must be an array of at most 16 intervals");
        chord.clear(); chord.setKeyNote(root); chord.setBass(bass); QSet<QString> seen;
        for (const auto value : spec.value("degrees").toArray()) {
            semanticRequire(value.isObject(), "Each degree must be an object");
            const auto degree = value.toObject(); semanticKeys(degree, {"value", "alteration", "omitted"});
            const QString v = semanticText(degree.value("value"), 32), a = semanticText(degree.value("alteration"), 32);
            const auto nv = Interval::valueFromString(v); const auto na = Interval::alterationFromString(a);
            semanticRequire(Interval::valueToString(nv) == v && Interval::alterationToString(na) == a && !seen.contains(v), "Invalid or duplicate chord interval");
            seen.insert(v); semanticRequire(!degree.contains("omitted") || degree.value("omitted").isBool(), "omitted must be boolean");
            const chord::Degree item(nv, na, degree.value("omitted").toBool());
            semanticRequire(item.isValid(), "Native chord interval is invalid"); chord.addDegree(item);
        }
    }
    if (spec.contains("name")) chord.setName(semanticText(spec.value("name"), 256));
    if (!spec.contains("diagram")) { score->setChord(range, chord, false, false); return; }
    semanticRequire(spec.value("diagram").isObject(), "diagram must be an object");
    const auto d = spec.value("diagram").toObject(); semanticKeys(d, {"first_fret", "fret_count", "frets", "barres", "fingers"});
    semanticRequire(d.value("frets").isArray(), "diagram.frets array required"); const auto frets = d.value("frets").toArray();
    semanticRequire(frets.size() >= 1 && frets.size() <= 12 && (!strings || frets.size() == strings), "Diagram frets must match the staff's string count");
    const int first = semanticInt(semanticDefault(d, "first_fret", 1), 1, 32, "first_fret"), count = semanticInt(semanticDefault(d, "fret_count", 5), 1, 12, "fret_count");
    chord::Diagram diagram(unsigned(frets.size()), unsigned(count)); diagram.setBaseFret(unsigned(first - 1));
    for (int s = 0; s < frets.size(); ++s) {
        const int fret = semanticInt(frets[s], -1, 36, "diagram fret");
        semanticRequire(fret <= 0 || (fret >= first && fret < first + count), "Diagram fret falls outside its displayed window");
        diagram.setFret(unsigned(s), unsigned(fret), static_cast<chord::Diagram::FretValueType>(0));
    }
    const auto fingers = std::make_shared<chord::Fingering>();
    QMap<QPair<int, int>, int> positions;
    const auto setFinger = [&](int string, int fret, int finger) {
        const QPair<int, int> key{string, fret};
        semanticRequire(!positions.contains(key) || positions.value(key) == finger, "Conflicting finger assignments");
        positions[key] = finger;
        fingers->setFinger(unsigned(fret), unsigned(string), static_cast<chord::Fingering::Finger>(finger));
    };
    semanticRequire(!d.contains("barres") || (d.value("barres").isArray() && d.value("barres").toArray().size() <= 12), "Invalid barres array");
    for (const auto value : d.value("barres").toArray()) {
        const auto b = value.toObject(); semanticKeys(b, {"from_string", "to_string", "fret", "finger"});
        const int from = semanticInt(b.value("from_string"), 0, frets.size() - 1, "barre.from_string"), to = semanticInt(b.value("to_string"), from + 1, frets.size() - 1, "barre.to_string"), fret = semanticInt(b.value("fret"), 1, count, "barre.fret");
        const int finger = semanticInt(semanticDefault(b, "finger", 1), 0, 4, "barre.finger");
        setFinger(from, fret, finger); setFinger(to, fret, finger);
    }
    semanticRequire(!d.contains("fingers") || (d.value("fingers").isArray() && d.value("fingers").toArray().size() <= 72), "Invalid fingers array");
    if (d.contains("fingers")) {
        for (const auto value : d.value("fingers").toArray()) {
            const auto f = value.toObject(); semanticKeys(f, {"string", "fret", "finger"});
            // The native setter takes (fret, string), while its getter takes (string, fret).
            setFinger(semanticInt(f.value("string"), 0, frets.size() - 1, "finger.string"), semanticInt(f.value("fret"), 0, count, "finger.fret"), semanticInt(f.value("finger"), 0, 4, "finger"));
        }
    }
    if (!positions.isEmpty()) diagram.setFingering(fingers);
    score->setChord(range, chord, diagram);
}
}
