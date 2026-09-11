#pragma once
#include <QtCore/QString>
#include <memory>
#include <string>
#include <vector>
#include <array>
#include <set>
#include <map>
#include <optional>
#include <functional>
#include <utility>
#include <list>
#include <QtCore/QStringList>
namespace am::filesystem {
class FileHandle;
class __declspec(dllimport) FileSystem {
public:
    enum class Mode : int { Read = 0, Write = 1 };
    std::unique_ptr<FileHandle, std::function<void(FileHandle *)>> openHandle(const QString &, Mode);
};
}
namespace am::music { enum class Accidental : int {}; enum class Dynamic : int {}; }
namespace am::painting {
class Color { public: int red, green, blue, alpha; };
class Size { public: double width, height; };
class Margins { public: double left, top, right, bottom; };
// AMPainting 8.1.1.17: vptr, enable_shared_from_this storage, private pointer.
class __declspec(dllimport) FormattedText {
    unsigned char storage[0x18];
public:
    FormattedText(const FormattedText &);
    virtual ~FormattedText();
    const std::string &text() const;
    void setText(const std::string &);
};
static_assert(sizeof(FormattedText) == 0x20);
}
namespace am::audio {
// AudioDeviceInfo owns QString fields at +0x10/+0x18 and a scalar vector at
// +0x28. The remaining native fields are copied without interpreting them.
struct AudioDeviceInfo {
    unsigned char nativePrefix[16];
    QString name, nativeLabel;
    unsigned char nativeOptions[8];
    std::vector<int> nativeValues;
};
static_assert(sizeof(AudioDeviceInfo) == 64);
// GP 8.1.1.17 audio ABI. These wrappers describe only the verified object
// size; the implementation remains owned by AMAudio.dll.
class Tick {
public:
    int value = 0;
    long long frameOffset = 0;
    long long frameCount = 0;
};
static_assert(sizeof(Tick) == 24 && alignof(Tick) == 8);
class __declspec(dllimport) IAudioBuffer {
    alignas(8) unsigned char storage[0x20];
public:
    enum class RawPolicy : int {};
    IAudioBuffer();
    ~IAudioBuffer() = default;
    void clear(); void unclear(); void lock(); void unlock();
    float *const *data(RawPolicy);
    const float *const *constData() const;
    bool empty() const;
    void fromInterleavedData(float *, unsigned);
    void toInterleavedData(float *, long long) const;
    void addToInterleavedData(float *, long long) const;
    long long add(const IAudioBuffer &);
    long long addScaled(const IAudioBuffer &, float);
    long long copyFrom(const IAudioBuffer &);
    void fill(float); void fill(unsigned, float); void scale(float); void clip();
};
static_assert(sizeof(IAudioBuffer) == 0x20 && alignof(IAudioBuffer) == 8);
class __declspec(dllimport) AudioBuffer {
    alignas(8) unsigned char storage[0x48];
public:
    AudioBuffer(); explicit AudioBuffer(unsigned);
    ~AudioBuffer() = default;
    unsigned channelCount() const;
    long long frameCount() const;
    const std::array<float *, 2> &rawData() const;
    void lock(); void unlock();
    void setChannelCount(unsigned); void setChannelData(unsigned, float *);
    void setFrameCount(long long);
};
static_assert(sizeof(AudioBuffer) == 0x48 && alignof(AudioBuffer) == 8);
class __declspec(dllimport) AudioCore {
public:
    static AudioCore &Instance();
    void allocAudioBufferData(AudioBuffer *);
    void freeAudioBuffer(AudioBuffer *);
    int samplingRate() const;
    long long audioBufferFrameCount() const;
};
class __declspec(dllimport) VolumePan {
public:
    VolumePan();
    ~VolumePan();
    bool isBypassed() const;
    unsigned parameterCount() const;
    float parameter(unsigned) const;
    void setBypassed(bool);
    void setParameter(unsigned, float);
    void reset();
    void process(IAudioBuffer &, const IAudioBuffer &);
};
class __declspec(dllimport) AudioLayer {
public:
    static AudioLayer &instance();
    QList<AudioDeviceInfo> outputDevices() const;
    QList<AudioDeviceInfo> inputDevices() const;
    std::vector<int> buffersSize() const;
    bool hasAsio() const; bool isRunning() const;
};
}
namespace am::utils {
class rational;
// Verified Color copy/read code uses exactly three bytes, without alpha.
class Color { public: unsigned char red, green, blue; };
static_assert(sizeof(Color) == 3 && alignof(Color) == 1);
}

// Declarations for verified MSVC x64 exports only. The host owns model objects.
// Only the value types with verified storage below are constructed locally.
#include "guitarpro_chord_abi.h"
namespace gp::core {
class Score;
namespace view { enum class Visibility : int { Visible = 0, Hidden = 1, Collapsed = 2 }; }
class __declspec(dllimport) ScoreView {
    alignas(8) unsigned char storage[0xa8];
public:
    ScoreView(); ~ScoreView();
    void applyModel(const ScoreView &);
};
static_assert(sizeof(ScoreView) == 0xa8);
namespace style {
namespace generated { class PageLayout { public: enum class Orientation : int { Portrait = 0, Landscape = 1 }; }; }
class __declspec(dllimport) Stylesheet {
    unsigned char storage[0x1488];
public:
    Stylesheet(const Stylesheet &);
    Stylesheet &operator=(const Stylesheet &);
    Stylesheet(const std::shared_ptr<Stylesheet> &);
    virtual ~Stylesheet();
    void applyModel(const std::shared_ptr<Stylesheet> &);
    static void setupStyleForExport(Stylesheet &);
};
static_assert(sizeof(Stylesheet) == 0x1490);
__declspec(dllimport) void setPageLayoutBackgroundColor(Stylesheet &, const std::optional<am::painting::Color> &);
__declspec(dllimport) am::painting::Size pageLayoutSizeValue(const Stylesheet &);
__declspec(dllimport) am::painting::Margins pageLayoutMarginsValue(const Stylesheet &);
__declspec(dllimport) generated::PageLayout::Orientation pageLayoutOrientationValue(const Stylesheet &);
__declspec(dllimport) void setPageLayoutSize(Stylesheet &, const std::optional<am::painting::Size> &);
__declspec(dllimport) void setPageLayoutMargins(Stylesheet &, const std::optional<am::painting::Margins> &);
__declspec(dllimport) void setPageLayoutOrientation(Stylesheet &, const std::optional<generated::PageLayout::Orientation> &);
#define GP_PAGE_FIELD(Name, Setter) \
__declspec(dllimport) am::painting::FormattedText Name##FormattedTextValue(const Stylesheet &); \
__declspec(dllimport) view::Visibility Name##VisibilityValue(const Stylesheet &); \
__declspec(dllimport) void Setter##FormattedText(Stylesheet &, const std::optional<am::painting::FormattedText> &); \
__declspec(dllimport) void Setter##Visibility(Stylesheet &, const std::optional<view::Visibility> &);
GP_PAGE_FIELD(scoreEvenPageHeaderField, setScoreEvenPageHeaderField)
GP_PAGE_FIELD(scoreOddPageHeaderField, setScoreOddPageHeaderField)
GP_PAGE_FIELD(scoreFirstPageFooterCopyright2, setScoreFirstPageFooterCopyright2)
GP_PAGE_FIELD(scoreEvenPageFooterCopyright2, setScoreEvenPageFooterCopyright2)
GP_PAGE_FIELD(scoreOddPageFooterCopyright2, setScoreOddPageFooterCopyright2)
GP_PAGE_FIELD(scoreFirstPageFooterPageNumber, setScoreFirstPageFooterPageNumber)
GP_PAGE_FIELD(scoreEvenPageFooterPageNumber, setScoreEvenPageFooterPageNumber)
GP_PAGE_FIELD(scoreOddPageFooterPageNumber, setScoreOddPageFooterPageNumber)
#undef GP_PAGE_FIELD
}
namespace io {
class Importer;
class Exporter {
public:
    virtual ~Exporter() = default;
    virtual const std::list<std::string> &defaultExporterExtensions() const = 0;
    virtual const std::string &exporterDescription() const = 0;
    virtual void reservedSaveWithArchive() = 0;
    virtual void reservedSaveWithRange() = 0;
    virtual bool saveFile(am::filesystem::FileHandle &, const Score &) = 0;
    virtual const std::list<std::string> &warnings() = 0;
    virtual void setVersion(const QString &) = 0;
    virtual void setRevision(const std::string &) = 0;
    virtual void setOption(int) = 0;
    virtual void saveAdditionalDatas(am::filesystem::FileHandle &, Score &) = 0;
};
}
class __declspec(dllimport) Core {
public:
    static Core &instance();
    am::filesystem::FileSystem *fileSystem() const;
    unsigned exportersCount() const;
    unsigned importersCount() const;
    std::string exporterDescription(unsigned) const;
    std::list<std::string> exporterExtensions(unsigned) const;
    QString importerDescription(unsigned) const;
    QStringList importerExtensions(unsigned) const;
    io::Exporter *exporterByExtension(const std::string &) const;
};
enum class ScoreProperty : int {};
enum class PlaybackState : int {};
enum class TempoUnit : int {};
enum class Vibrato : int {};
enum class AntiAccent : int {};
enum class Fingering : int {};
enum class TupletLevel : int {};
enum class SlideFlag : int {};
enum class Ornament : int {};
enum class GraceType : int {};
enum class Direction : int {};
enum class Fadding : int {};
enum class Hairpin : int {};
enum class Golpe : int {};
enum class Ottavia : int {};
enum class DirectionMark : int {};
enum class AccentFlag : int {};
enum class Rasgueado : int {};
enum class BassAttack : int {};
enum class Clef : int {};
enum class StemOrientation : int {};
struct Harmonic {
    enum class Type : int {};
    enum class Fret : int {};
    __declspec(dllimport) static std::string typeToString(Type);
    __declspec(dllimport) static float fretToFloat(Fret);
};
using TupletRatio = std::pair<unsigned char, unsigned char>;
static_assert(sizeof(TupletRatio) == 2 && alignof(TupletRatio) == 1);
class __declspec(dllimport) InstrumentArticulation {
    void *implementation;
public:
    const std::string &name() const; unsigned outputMidiNumber() const;
};
static_assert(sizeof(InstrumentArticulation) == 8);
class InstrumentSet {
public:
    enum class Type : int {};
    __declspec(dllimport) static std::string typeToString(Type);
    __declspec(dllimport) static bool isStringed(Type);
    __declspec(dllimport) static bool isUnpitched(Type);
    __declspec(dllimport) bool isUnpitched() const;
    __declspec(dllimport) int indexOfArticulationWithMidi(unsigned) const;
    __declspec(dllimport) const std::vector<InstrumentArticulation> &articulations() const;
};
class ScoreModel;
class MasterBar;
class TimeSignature {
    unsigned numerator, denominator;
    __declspec(dllimport) TimeSignature(unsigned, unsigned);
public:
    // The native constructor is private; validation precedes this local factory.
    static TimeSignature fromValues(unsigned numerator, unsigned denominator) { return TimeSignature(numerator, denominator); }
    __declspec(dllimport) unsigned getNumerator() const;
    __declspec(dllimport) unsigned getDenominator() const;
};
static_assert(sizeof(TimeSignature) == 8 && alignof(TimeSignature) == 4);
class __declspec(dllimport) KeySignature {
    unsigned char data[8]; // Native vptr plus accidental count and two booleans: 16 bytes.
public:
    KeySignature(int, bool);
    virtual ~KeySignature();
    KeySignature(const KeySignature &) = delete;
    KeySignature &operator=(const KeySignature &) = delete;
    int accidentalCount() const; bool isMajor() const; QString toQString() const;
};
static_assert(sizeof(KeySignature) == 16 && alignof(KeySignature) == 8);
class __declspec(dllimport) MasterBar {
public:
    struct Section {
        std::string name;
        std::string text;
    };
    static_assert(sizeof(Section) == 0x40 && alignof(Section) == 8);
    unsigned index() const; ScoreModel *model() const; int tickCount() const;
    const TimeSignature &timeSignature() const;
    const KeySignature &concertKeySignature() const;
    bool hasRepeatStart() const; bool hasRepeatEnd() const; unsigned repeatCount() const;
    bool hasDoubleBar() const; bool hasFreeTime() const;
    int alternateEndingMask() const;
    bool hasSection() const;
    const Section &section() const;


};
class __declspec(dllimport) Automation {
public:
    enum class Type : int {};
    static std::shared_ptr<Automation> make(Type);
    virtual ~Automation();
    virtual unsigned barIndex() const;
    virtual std::shared_ptr<Automation> cloneAutomation() const;
    float position() const; float value() const; bool isLinear() const;
    const std::string &text() const;
    virtual void setBarIndex(unsigned);
    void setPosition(float); void setValue(float); void setLinear(bool); void setText(const std::string &);
    Type type() const;
    static Type typeFromString(const std::string &);
    static const std::string typeToString(Type);
};
class __declspec(dllimport) DSPParamAutomation : public Automation {
public:
    std::shared_ptr<Automation> cloneAutomation() const override;
    int parameterId() const;
};
class __declspec(dllimport) SoundAutomation : public Automation {
public:
    std::shared_ptr<Automation> cloneAutomation() const override;
    virtual void valueFromString(const std::string &);
    virtual std::string valueToString() const;
};
class __declspec(dllimport) TempoAutomation : public Automation {
public:
    virtual std::shared_ptr<Automation> cloneAutomation() const;
    TempoUnit unit() const; void setUnit(TempoUnit);
};
class __declspec(dllimport) AutomationContainerProxy {
public:
    virtual void getAutomations(std::vector<std::shared_ptr<Automation>> &) const;
    virtual void getAutomations(Automation::Type, std::vector<std::shared_ptr<Automation>> &) const;
    virtual void forEachBypass(const std::function<void(Automation::Type, bool)> &) const;
};
class __declspec(dllimport) Timeline {
public:
    std::vector<int> tickOffsets(int) const;
    int tickCount() const;
};
class __declspec(dllimport) MasterTrack : public AutomationContainerProxy {
public:
    unsigned masterBarCount() const;
    const std::string &tempoLabel() const;
    TempoUnit tempoUnit() const; float tempoValue() const;
    std::shared_ptr<MasterBar> masterBar(unsigned) const;
    std::set<DirectionMark> directionsAtBarIndex(int) const;
    static QString directionToQString(DirectionMark);
    const Timeline &timeline() const;
};
class Beat;
class Note;
class __declspec(dllimport) ScoreModelIndex {
    void *implementation; // Native value owns a 0x38-byte implementation.
public:
    ScoreModelIndex(ScoreModel *, int, int, int, unsigned, unsigned);
    ~ScoreModelIndex();
    ScoreModelIndex(const ScoreModelIndex &) = delete;
    ScoreModelIndex &operator=(const ScoreModelIndex &) = delete;
    int trackIndex() const; int barIndex() const; int beatIndex() const;
    unsigned staffIndex() const; unsigned voiceIndex() const;
    unsigned noteString() const; unsigned noteMidi() const;
    std::shared_ptr<Beat> beat() const;
    std::shared_ptr<Note> note() const;
    void setNoteString(unsigned); void setNoteMidi(unsigned);
};
static_assert(sizeof(ScoreModelIndex) == 8 && alignof(ScoreModelIndex) == 8);
class __declspec(dllimport) ScoreModelRange {
    // Verified constructor/destructor own one pointer to a 0x20-byte implementation.
    void *implementation;
public:
    enum class SortingPolicy : int {};
    ScoreModelRange(const ScoreModelIndex &, unsigned, SortingPolicy);
    ScoreModelRange(const ScoreModelIndex &, const ScoreModelIndex &, unsigned, SortingPolicy);
    ~ScoreModelRange();
    ScoreModelRange(const ScoreModelRange &) = delete;
    ScoreModelRange &operator=(const ScoreModelRange &) = delete;
    unsigned barCount() const; unsigned beatCount() const;
    bool isMultiTrack() const; bool isMultiVoice() const; bool isPlaceholder() const;
    const ScoreModelIndex &baseModelIndex() const;
    const ScoreModelIndex &extentModelIndex() const;
    const ScoreModelIndex &lowerModelIndex() const; const ScoreModelIndex &upperModelIndex() const;
    unsigned selectionModes() const; void setSelectionModes(unsigned);
    ScoreModelIndex &mutableBaseModelIndex(); ScoreModelIndex &mutableExtentModelIndex();
    void setMultiSelection(bool); bool isMultiSelection() const;
};
static_assert(sizeof(ScoreModelRange) == 8 && alignof(ScoreModelRange) == 8);
namespace flatten {
__declspec(dllimport) std::vector<Beat *> beats(const ScoreModelRange &);
}
class Score;
class __declspec(dllimport) SerializedScore {
    void *implementation; // Native vptr + owned 0x210-byte implementation.
public:
    enum class OverridingMode : int {};
    SerializedScore(const ScoreModelRange &);
    virtual ~SerializedScore();
    SerializedScore(const SerializedScore &) = delete;
    SerializedScore &operator=(const SerializedScore &) = delete;
    unsigned barCount() const;
    bool isMultiTrack() const; bool isMultiVoice() const;
    bool isCompatibleWith(const Score &) const;
    unsigned long long incompatiblePasteTypeWith(const Score &) const;
    const Score &score() const;
};
static_assert(sizeof(SerializedScore) == 16 && alignof(SerializedScore) == 8);
class __declspec(dllimport) MacroCommandRecorder {
    // Verified fields: committed bool at 0, Score* at 8, execute bool at 16.
    alignas(8) unsigned char storage[24];
public:
    MacroCommandRecorder(Score *, bool);
    ~MacroCommandRecorder();
    MacroCommandRecorder(const MacroCommandRecorder &) = delete;
    MacroCommandRecorder &operator=(const MacroCommandRecorder &) = delete;
    void commit();
};
static_assert(sizeof(MacroCommandRecorder) == 24 && alignof(MacroCommandRecorder) == 8);
class __declspec(dllimport) Note {
public:
    int midi() const; int fret() const; unsigned string() const;
    unsigned soundingMidi(bool) const; InstrumentSet::Type type() const;
    am::music::Accidental accidental() const;
    bool isPalmMuted() const; bool hasLetRing() const;
    bool isLeftHandTapped() const; bool isTapped() const;
    bool isTieOrigin() const; bool isTieDestination() const;
    unsigned slideFlags() const;
    bool isSlideValid() const; bool isShiftSlideDestination() const; bool isLegatoSlideDestination() const;
    bool isHarmonic() const; Harmonic::Type harmonicType() const; Harmonic::Fret harmonicFret() const;
    bool isDead() const; bool isHopoOrigin() const; bool isHopoDestination() const;
    bool hasOrnament() const; Ornament ornament() const;
    unsigned accentFlags() const; bool isTrilled() const; unsigned trillMidi() const;
    bool isBended() const; bool isBendValid() const;
    float bendOriginValue() const; float bendMiddleValue() const; float bendDestinationValue() const;
    float bendOriginOffset() const; float bendMiddleOffset1() const; float bendMiddleOffset2() const; float bendDestinationOffset() const;
    Vibrato vibrato() const; AntiAccent antiAccent() const;
    Fingering leftHandFingering() const; Fingering rightHandFingering() const;
};
class __declspec(dllimport) RhythmValue {
    // GP 8.1.1.17: constructor/destructor and vector stride verify 0x38 bytes,
    // alignment 8. Native code manages the rational at +0x10 and cache at +0x30.
    alignas(8) unsigned char storage[0x38];
public:
    enum class Value : int {};
    RhythmValue(Value, int, int, int);
    ~RhythmValue();
    RhythmValue(const RhythmValue &) = delete;
    RhythmValue &operator=(const RhythmValue &) = delete;
    Value getNoteValue() const; unsigned getAugmentationDot() const;
    const TupletRatio &getTupletRatio(TupletLevel) const;
    bool hasTuplet(TupletLevel) const;
    QString toQString() const;
    const am::utils::rational &getLength() const;
    static Value noteValueFromTimeUnit(const am::utils::rational &);
};
static_assert(sizeof(RhythmValue) == 0x38 && alignof(RhythmValue) == 8);
class __declspec(dllimport) LyricsElement {
    // The host value contains a vptr, a small-string std::string and two
    // scalar fields. Only the const text accessor is used by the bridge.
    alignas(8) unsigned char storage[0x40];
public:
    const std::string &text() const;
};
static_assert(sizeof(LyricsElement) == 0x40 && alignof(LyricsElement) == 8);
class __declspec(dllimport) Beat {
public:
    const std::vector<std::shared_ptr<Note>> &notes() const;
    bool isRest() const; bool isPlaceholder() const; const RhythmValue &rhythm() const;
    const std::string &freeText() const;
    const class NoteDynamic &dynamic() const;
    const QString &chord() const;
    const std::array<LyricsElement, 5> &lyrics() const;
    StemOrientation drawingUserStemOrientation() const;
    StemOrientation userConcertPitchStemOrientation() const;
    StemOrientation userTransposedPitchStemOrientation() const;
    bool hasUserConcertPitchStemOrientation() const;
    bool hasUserTransposedPitchStemOrientation() const;
    void setLyrics(const std::string &, unsigned);
    bool isLegatoOrigin() const; bool isLegatoDestination() const;
    GraceType graceType() const; Direction pickStroke() const;
    Fadding fadding() const; Hairpin hairpin() const; Golpe golpe() const; Ottavia ottavia() const;
    bool isDeadSlapped() const;
    bool hasTremolo() const; const am::utils::rational &tremolo() const;
    Rasgueado rasgueado() const; Vibrato vibratoWTremBar() const;
    bool isSlapped() const; bool isPopped() const;
    Direction arpeggio() const; Direction brush() const;
    bool canSetArpeggio() const; bool canSetBrush() const;
    bool hasWhammyBar() const;
    float whammyBarOriginValue() const; float whammyBarMiddleValue() const; float whammyBarDestinationValue() const;
    float whammyBarOriginOffset() const; float whammyBarMiddleOffset1() const; float whammyBarMiddleOffset2() const; float whammyBarDestinationOffset() const;
};
class __declspec(dllimport) Voice {
public:
    const std::vector<std::shared_ptr<Beat>> &beats() const;
};
class __declspec(dllimport) Bar {
public:
    bool isSimileBar() const;
    Clef clef() const;
    const std::array<std::shared_ptr<Voice>, 4> &voices() const;
};
class __declspec(dllimport) NoteDynamic {
public:
    am::music::Dynamic value() const;
    std::string toString() const;
    static int stringToInt(const std::string &);
};
class __declspec(dllimport) GuitarTuning {
    // QObject's two pointers followed by the native tuning implementation.
    void *objectPrivate, *implementation;
public:
    GuitarTuning(const GuitarTuning &); virtual ~GuitarTuning();
    unsigned stringCount() const;
    const std::vector<int> &midiNumbers() const; void setMidiNumbers(const std::vector<int> &);
};
static_assert(sizeof(GuitarTuning) == 24 && alignof(GuitarTuning) == 8);
class __declspec(dllimport) Staff {
public:
    chord::ChordCollection &chordCollection() const;
    chord::DiagramCollection &diagramCollection() const;
    const std::vector<std::shared_ptr<Bar>> &bars() const;
    GuitarTuning &tuning() const;
    int midi(unsigned, int) const;
    unsigned char capoFret() const; unsigned char partialCapoFret() const;
    const std::vector<bool> &partialCapoStringFlags() const;
};
class __declspec(dllimport) ScoreCursor {
    void *implementation; // Native constructor and clone allocate an 8-byte value.
public:
    ScoreCursor(); ~ScoreCursor();
    ScoreCursor(const ScoreCursor &) = delete;
    ScoreCursor &operator=(const ScoreCursor &) = delete;
    void copy(const ScoreCursor &);
    void moveToCursorAndNotify(const ScoreCursor &, const ScoreCursor *);
    void select(const ScoreModelIndex &, const ScoreModelIndex &);
    void selectAll(); void selectMultiTrack(); void endMultiSelection();
    void selectNote(const std::shared_ptr<const Note> &, int);
    void setMultiVoice(bool);
    void setLastUserSelectionRange(const ScoreModelRange &);
    const ScoreModelIndex &modelIndex() const;
    const ScoreModelRange &selectionRange() const;
    const RhythmValue &nextInsertRhythm() const;
    std::shared_ptr<Beat> beat() const;
    std::shared_ptr<Staff> staff() const;
    int barIndex() const; int beatIndex() const; int trackIndex() const;
    unsigned noteMidi() const; unsigned noteString() const;
    unsigned staffIndex() const; unsigned voiceIndex() const;
    bool trySetBarIndex(int); bool trySetBeatIndex(int); bool trySetTrackIndex(int);
    bool trySetStaffIndex(unsigned); void setVoiceIndex(unsigned);
};
static_assert(sizeof(ScoreCursor) == 8 && alignof(ScoreCursor) == 8);
class __declspec(dllimport) TrackBase {
public:
    enum class Type : int {};
    int index() const;
    const std::string &name() const; const std::string &shortName() const;
    PlaybackState playbackState() const;
    float volume() const; float pan() const;
    const am::utils::Color &color() const;
    ScoreModel *parentScoreModel() const;
};
class __declspec(dllimport) Effect {
public:
    virtual ~Effect();
    const std::string &id() const; bool isBypass() const;
    const std::vector<float> &parameters() const;
    void setBypass(bool); void setParameter(unsigned, float);
};
class __declspec(dllimport) EffectChain {
public:
    const std::vector<std::unique_ptr<Effect>> &effects() const;
    Effect *effect(unsigned) const;
    void swapEffects(unsigned, unsigned); void removeEffect(unsigned);
};
class __declspec(dllimport) RSESound {
public:
    const EffectChain &effectChain() const; EffectChain &mutableEffectChain();
};
class __declspec(dllimport) MIDISound {
public:
    unsigned program() const; unsigned msbBank() const; unsigned lsbBank() const;
    void setProgram(unsigned);
};
class __declspec(dllimport) Sound {
    void *implementation;
public:
    Sound(const Sound &); ~Sound();
    Sound &operator=(const Sound &) = delete;
    const std::string &name() const; const std::string &label() const;
    const RSESound &rseSound() const; RSESound &mutableRseSound();
    const MIDISound &midiSound() const; MIDISound &mutableMidiSound();
};
static_assert(sizeof(Sound) == 8);
class __declspec(dllimport) Track {
public:
    const std::vector<std::shared_ptr<Staff>> &staves() const;
    unsigned barCount() const; unsigned staffCount() const;
    InstrumentSet::Type type() const; int transpositionOffset() const;
    const InstrumentSet &instrumentSet() const;
    int defaultBarCountBySystem() const;
    const std::vector<std::shared_ptr<Sound>> &sounds() const;
    int forcedSoundIndex() const;
};
class __declspec(dllimport) Score : public std::enable_shared_from_this<Score> {
    // Native make_shared allocation at 0x1C5297 is 0x1F8, including its
    // 0x10-byte control block. The first 0x10 bytes are enable_shared_from_this.
    alignas(8) unsigned char storage[0x1D8];
public:
    Score();
    ~Score();
    Score(const Score &) = delete;
    Score &operator=(const Score &) = delete;
    Score &copyFrom(std::shared_ptr<const Score>, const ScoreModelRange *);
    void load(const QString &);
    void replaceScore(const std::shared_ptr<Score> &, int);
    ScoreView &activeView();
    const std::shared_ptr<style::Stylesheet> &newStylesheet() const;
    bool hasStdNotation(int);
    bool hasTablature(int);
    void setStdNotation(Track &, bool);
    void setTablature(Track &, bool);
    // Seven floats, copied by the native entry and consumed in this order.
    struct BendParam {
        float originValue, middleValue, destinationValue;
        float originOffset, middleOffset1, middleOffset2, destinationOffset;
    };
    static_assert(sizeof(BendParam) == 28 && alignof(BendParam) == 4);
    struct WhammyBarParam {
        float originValue, middleValue, destinationValue;
        float originOffset, middleOffset1, middleOffset2, destinationOffset;
    };
    static_assert(sizeof(WhammyBarParam) == 28 && alignof(WhammyBarParam) == 4);
    const std::shared_ptr<ScoreModel> &modelPrivate() const;
    std::string property(ScoreProperty) const;
    void setStringedNoteFret(const ScoreModelIndex &, unsigned, int, am::music::Accidental);
    void setMIDINote(const ScoreModelRange &, unsigned);
    void createNonPitchedNote(const ScoreModelRange &, const RhythmValue &, const InstrumentArticulation &);
    void removeNonPitchedNoteFromMidiAndString(const ScoreModelIndex &, unsigned, unsigned);
    void setStringedNote(const ScoreModelRange &, bool, int, int, am::music::Accidental, const RhythmValue &);
    void clearBeat(const ScoreModelIndex &); void removeBeat(const ScoreModelIndex &);
    void clearBeatRange(const ScoreModelRange &);
    void removeBeatRange(const ScoreModelRange &);
    void pasteBeatRange(const std::shared_ptr<SerializedScore> &, const ScoreModelRange &, unsigned, SerializedScore::OverridingMode);
    void pasteBarRange(const std::shared_ptr<SerializedScore> &, const ScoreModelRange &, unsigned, SerializedScore::OverridingMode);
    void setBeatRhythm(const ScoreModelRange &, const RhythmValue &);
    void setNoteAugmentationDot(const ScoreModelRange &, bool, unsigned);
    void setBeatTuplet(const ScoreModelRange &, bool, const TupletRatio &, TupletLevel);
    void setBeatLegato(const ScoreModelRange &, bool);
    void setBeatTied(const ScoreModelRange &, bool);
    void setNoteTied(const ScoreModelRange &, bool);
    void setStringedNotePalmMute(const ScoreModelRange &, bool, bool);
    void setNoteLetRing(const ScoreModelRange &, bool, bool);
    void setStringedNoteLeftHandTapping(const ScoreModelRange &, bool);
    void setStringedNoteRightHandTapping(const ScoreModelRange &, bool);
    void setStringedNoteVibrato(const ScoreModelRange &, bool, Vibrato);
    void setNoteAntiAccent(const ScoreModelRange &, bool, AntiAccent);
    void setNoteLeftHandFingering(const ScoreModelRange &, bool, Fingering);
    void setNoteRightHandFingering(const ScoreModelRange &, bool, Fingering);
    void setStringedNoteSlide(const ScoreModelRange &, bool, SlideFlag, int, int);
    void unsetStringedNoteSlide(const ScoreModelRange &);
    void setStringedNoteNaturalHarmonic(const ScoreModelRange &, bool, Harmonic::Fret);
    void setStringedNoteArtificialHarmonic(const ScoreModelRange &, bool, Harmonic::Type, Harmonic::Fret);
    void unsetStringedNoteHarmonic(const ScoreModelRange &);
    void setStringedNoteBend(const ScoreModelRange &, bool, BendParam, bool);
    void setStringedNoteDead(const ScoreModelRange &, bool, int, int);
    void setStringedNoteHopo(const ScoreModelRange &, bool, bool);
    void setNoteOrnament(const ScoreModelRange &, bool, Ornament);
    void setNoteAccentFlag(const ScoreModelRange &, bool, AccentFlag);
    void setNoteTrill(const ScoreModelRange &, bool, unsigned, unsigned);
    void setBeatGraceNotes(const ScoreModelRange &, bool, GraceType);
    void setBeatPickStroke(const ScoreModelRange &, bool, Direction);
    void setBeatFadding(const ScoreModelRange &, bool, Fadding);
    void setBeatHairpin(const ScoreModelRange &, bool, Hairpin);
    void setBeatGolpe(const ScoreModelRange &, bool, Golpe);
    void setBeatOttavia(const ScoreModelRange &, bool, Ottavia, bool);
    void setBeatDeadSlapped(const ScoreModelRange &, bool);
    void setBeatTremolo(const ScoreModelRange &, bool, const am::utils::rational &);
    void setBeatRasgueado(const ScoreModelRange &, Rasgueado);
    void setStringedBeatBassAttack(const ScoreModelRange &, bool, BassAttack);
    void setStringedBeatVibrato(const ScoreModelRange &, bool, Vibrato);
    void setArpeggioPattern(const ScoreModelRange &, const std::vector<Direction> &, bool);
    void setBrushPattern(const ScoreModelRange &, const std::vector<Direction> &, bool);
    void setBeatArpeggio(const ScoreModelRange &, bool, Direction, int, float);
    void setBrush(const ScoreModelRange &, bool, Direction, int, float);
    void setStringedBeatWhammyBar(const ScoreModelRange &, bool, WhammyBarParam);
    void createBars(unsigned, unsigned); void removeBarRange(unsigned, unsigned);
    void createBeat(const ScoreModelRange &, const RhythmValue &);
    void setProperty(ScoreProperty, const std::string &);
    void setChord(const ScoreModelRange &, const chord::Chord &, bool, bool);
    void setChord(const ScoreModelRange &, const chord::Chord &, const chord::Diagram &);
    void unsetChord(const ScoreModelRange &);
    void setBeatFreeText(const ScoreModelRange &, const std::string &, bool);
    void setBeatDynamic(const ScoreModelRange &, am::music::Dynamic, bool);
    void setAutoStemOrientations(const ScoreModelRange &);
    void setUserStemOrientations(const ScoreModelRange &, StemOrientation);
    void setClef(const ScoreModelRange &, Clef, Ottavia, bool);
    void setMasterBarSection(unsigned, bool, const MasterBar::Section &, bool);
    void unsetMasterBarSection(const ScoreModelRange &);
    void setTempo(const std::string &, TempoUnit, float);
    void modifyMasterTrackAutomations(const std::vector<std::shared_ptr<Automation>> &, const std::map<Automation::Type, bool> &);
    void modifyTrackAutomations(TrackBase::Type, int, const std::vector<std::shared_ptr<Automation>> &, const std::map<Automation::Type, bool> &);
    void setTrackSound(Track &, unsigned, const Sound &, bool);
    void setForcedSoundIndex(Track &, int);
    void setMasterBarTimeSignature(const ScoreModelRange &, bool, const TimeSignature &);
    void setMasterBarKeySignature(const ScoreModelRange &, bool, const KeySignature &, bool);
    void setBarRepeatStart(const ScoreModelRange &, bool);
    void setBarRepeatEnd(const ScoreModelRange &, bool, int);
    void setBarAlternateEndings(const ScoreModelRange &, bool, int, bool);
    void setBarDirection(const ScoreModelRange &, bool, DirectionMark);
    void setMasterBarDoubleBar(const ScoreModelRange &, bool);
    void setMasterBarFreeTime(const ScoreModelRange &, bool);
    unsigned trackCount() const;
    const std::vector<std::shared_ptr<Track>> &tracks() const;
    std::shared_ptr<TrackBase> track(TrackBase::Type, unsigned) const;
    std::shared_ptr<MasterTrack> masterTrack() const;
    void createTrack(unsigned, const std::shared_ptr<Track> &, unsigned, bool, bool, bool, unsigned);
    void duplicateTrack(unsigned); void removeTrack(unsigned); void swapTracks(unsigned, unsigned);
    void setTrackName(TrackBase &, const std::string &); void setTrackShortName(TrackBase &, const std::string &);
    void setTrackPlaybackState(TrackBase &, PlaybackState);
    void setTrackChannelStripParameter(TrackBase &, unsigned, float);
    void setTrackColor(TrackBase &, const am::utils::Color &);
    void setTrackTranspositionOffset(Track &, int);
    void transposeTrackBySemitones(const ScoreModelRange &, int, bool, bool, bool);
    void setGuitarFullTuning(Staff &, const GuitarTuning &, int, int, const std::vector<bool> &, bool);
    ScoreCursor &cursor();
    bool undoAvailable() const; bool redoAvailable() const;
    void undo(); void redo();
};
static_assert(sizeof(Score) == 0x1E8 && alignof(Score) == 8);
__declspec(dllimport) QString scorePropertyToQString(ScoreProperty);
__declspec(dllimport) std::string playbackStateToString(PlaybackState);
__declspec(dllimport) std::string tempoUnitToString(TempoUnit);
__declspec(dllimport) Clef clefFromString(const std::string &);
__declspec(dllimport) std::string clefToString(Clef);
__declspec(dllimport) StemOrientation stemOrientationFromString(const std::string &);
__declspec(dllimport) std::string stemOrientationToString(StemOrientation);
__declspec(dllimport) float convertTempo(float, TempoUnit, TempoUnit);
__declspec(dllimport) std::string vibratoToString(Vibrato);
__declspec(dllimport) std::string antiAccentToString(AntiAccent);
__declspec(dllimport) std::string fingeringToString(Fingering);
__declspec(dllimport) std::string ornamentToString(Ornament);
__declspec(dllimport) std::string graceTypeToString(GraceType);
__declspec(dllimport) std::string directionToString(Direction);
__declspec(dllimport) std::string faddingToString(Fadding);
__declspec(dllimport) std::string hairpinToString(Hairpin);
__declspec(dllimport) std::string golpeToString(Golpe);
__declspec(dllimport) std::string ottaviaToString(Ottavia);
__declspec(dllimport) std::string rasgueadoToString(Rasgueado);
}
namespace gp::rse {
class Master;
class MasterTrack;
class __declspec(dllimport) EffectsChain {
public:
    unsigned index() const;
    void setIndex(unsigned);
    const std::string &name() const;
    EffectsChain *clone() const;
    void process(am::audio::IAudioBuffer &, const std::vector<am::audio::Tick> &);
    void processDSP(am::audio::IAudioBuffer &, const std::vector<am::audio::Tick> &);
};
class __declspec(dllimport) SESoundConverter {
public:
    static std::shared_ptr<EffectsChain> convertEffectChain(const gp::core::EffectChain &);
};
class __declspec(dllimport) Sound {
public:
    const std::shared_ptr<EffectsChain> &effectChain() const;
    void setEffectChain(const std::shared_ptr<EffectsChain> &);
};
class __declspec(dllimport) Musician {
public:
    const std::shared_ptr<gp::core::Track> &coreTrack() const;
    std::shared_ptr<Sound> soundAtIndex(unsigned) const;
    void updateAll();
};
class __declspec(dllimport) PlaybackRange {
public:
    int playTickOffset() const; int endTickOffset() const;
    int loopPlayTickOffset() const; int loopEndTickOffset() const;
};
class __declspec(dllimport) Metronome {
public:
    bool isEnabled() const; bool isCountdownEnabled() const; unsigned countdownBarCount() const;
};
class __declspec(dllimport) Conductor {
public:
    const std::shared_ptr<gp::core::Score> &score() const;
    Musician *musician(unsigned) const;
    std::shared_ptr<Sound> sound(unsigned, unsigned) const;
    Master &master() const;
    MasterTrack &masterTrack() const;
    unsigned barCount() const;
    int tickCount() const; int tickOffset() const; int tickOffset(unsigned) const;
    long long frameOffset() const;
    long long frameCount() const;
    long long frameCount(int, int) const;
    const PlaybackRange &playbackRange() const;
    void resetPlaybackRange();
    bool isUpdatingData() const;
    void updateTempoManagerAsync(const std::function<void()> &);
};
class __declspec(dllimport) ConductorController {
public:
    const std::shared_ptr<Conductor> &conductor() const;
    bool isPlaying() const; bool isLoopEnabled() const; bool isCountingDown() const;
    const Metronome &metronome(); float metronomeVolume() const;
    void play(); void stop(); void seek(unsigned, int); void seek(int);
    void setLoopEnabled(bool); void setMetronomeEnabled(bool); void setCountdownEnabled(bool);
    void setMetronomeVolume(float); void setCountdownBarCount(unsigned);
};
class __declspec(dllimport) AudioExportManager {
    void *implementation;
public:
    AudioExportManager(const std::shared_ptr<gp::core::Score> &);
    virtual ~AudioExportManager();
    void prepareConductorForEncoding(const std::optional<int> &);
    void setExportMetronome(bool); void setExportCountdown(bool); void setExportSelection(bool);
    unsigned processFrame(std::vector<float> &, std::vector<float> &);
    long long soundingLengthInFrames() const;
};
static_assert(sizeof(AudioExportManager) == 16);
}
