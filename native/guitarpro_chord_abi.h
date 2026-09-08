#pragma once

// Value layouts and exported entry points for the hash-verified GP 8.1.1.17.
// Constructors, destructors and collection lookup remain owned by GPCore.
namespace gp::core {
class __declspec(dllimport) PitchClass {
    unsigned char data[8];
public:
    PitchClass(const PitchClass &);
    virtual ~PitchClass();
    static PitchClass fromString(const QString &);
    QString toString() const;
};
static_assert(sizeof(PitchClass) == 16);
class __declspec(dllimport) Interval {
public:
    enum class Value : int {};
    enum class Alteration : int {};
    // Confirmed at 0x34AE80; the native exported value has public scalar data.
    Alteration alteration;
    Value value;
    virtual ~Interval();
    bool isValid() const;
    static Value valueFromString(const QString &);
    static QString valueToString(Value);
    static Alteration alterationFromString(const QString &);
    static QString alterationToString(Alteration);
};
static_assert(sizeof(Interval) == 16);
namespace diagram {
class __declspec(dllimport) FreeDiagram {
    unsigned char data[16];
public:
    virtual ~FreeDiagram();
    unsigned baseFret() const;
    void setBaseFret(unsigned);
    unsigned fretCount() const;
};
static_assert(sizeof(FreeDiagram) == 24);
}
namespace chord {
class __declspec(dllimport) Degree : public Interval {
public:
    bool omitted;
    Degree(Interval::Value, Interval::Alteration, bool);
    Degree(const Degree &);
    virtual ~Degree();
};
static_assert(sizeof(Degree) == 24);
class __declspec(dllimport) Chord {
    unsigned char data[0x48];
public:
    enum class Type : int {};
    enum class Inversion : int {};
    Chord(const PitchClass &, const PitchClass &, Type);
    virtual ~Chord();
    void clear();
    void setKeyNote(const PitchClass &); void setBass(const PitchClass &);
    void setName(const QString &); void addDegree(const Degree &);
    QString name() const;
    PitchClass keyNote() const; PitchClass bass() const;
    Type type() const; Inversion inversion() const;
    std::vector<Degree> degrees() const;
    static QString chordTypeToString(Type);
};
static_assert(sizeof(Chord) == 0x50);
class __declspec(dllimport) Fingering {
    void *implementation;
public:
    enum class Finger : int {};
    Fingering();
    virtual ~Fingering();
    void setFinger(unsigned, unsigned, Finger);
    Finger finger(unsigned, unsigned) const;
    bool bar(int) const;
};
static_assert(sizeof(Fingering) == 16);
class __declspec(dllimport) Diagram : public diagram::FreeDiagram {
    unsigned char data[0x68];
public:
    enum class FretValueType : int {};
    Diagram(unsigned, unsigned);
    virtual ~Diagram();
    virtual unsigned stringCount() const;
    unsigned fret(unsigned, FretValueType) const;
    void setFret(unsigned, unsigned, FretValueType);
    const Fingering *fingering() const;
    void setFingering(std::shared_ptr<const Fingering>);
};
static_assert(sizeof(Diagram) == 0x80);
class __declspec(dllimport) ChordEntry {
public:
    const Chord *chord() const; QString name() const;
};
class __declspec(dllimport) DiagramEntry {
public:
    const Chord *chord() const; const Diagram &diagram() const; QString name() const;
};
class __declspec(dllimport) ChordCollectionItem { public: const ChordEntry &entry() const; };
class __declspec(dllimport) DiagramCollectionItem { public: const DiagramEntry &entry() const; };
class __declspec(dllimport) ChordCollection { public: const ChordCollectionItem *find(const QString &) const; };
class __declspec(dllimport) DiagramCollection { public: const DiagramCollectionItem *find(const QString &) const; };
}
}
