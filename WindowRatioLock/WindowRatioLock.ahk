#Requires AutoHotkey v2.0
#SingleInstance Force


;==============================================================================
; DPI Awareness
;------------------------------------------------------------------------------
; Enable per-thread DPI awareness whenever supported by the operating system.
; This prevents incorrect scaling on high-DPI displays.
;==============================================================================

try
{
    DllCall("SetThreadDpiAwarenessContext", "ptr", -4)
}
catch
{
    ; DPI awareness is not available on this version of Windows.
}


;==============================================================================
; Administrator Privileges
;------------------------------------------------------------------------------
; Restart the script with elevated privileges when required.
;
; Administrator rights are necessary to interact reliably with elevated
; applications and certain system windows.
;==============================================================================

if !A_IsAdmin
{
    Loop
    {
        try
        {
            Run '*RunAs "' A_ScriptFullPath '"'
            ExitApp()
        }
        catch
        {
            result := MsgBox(
                Lang("AdminRightsRequired"),
                Lang("AppName"),
                "RetryCancel Icon!"
            )

            if (result = "Retry")
                continue

            ExitApp()
        }
    }
}


;==============================================================================
; Constants
;==============================================================================

;------------------------------------------------------------------------------
; Windows Event IDs
;------------------------------------------------------------------------------

EVENT_SYSTEM_MOVESIZESTART := 0x000A
EVENT_SYSTEM_MOVESIZEEND   := 0x000B

EVENT_OBJECT_CREATE := 0x8000
EVENT_OBJECT_SHOW   := 0x8002


;------------------------------------------------------------------------------
; Aspect Ratio Settings
;------------------------------------------------------------------------------

RATIO_TOLERANCE := 0.02

CHILD_MIN_WIDTH_RATIO  := 0.70
CHILD_MIN_HEIGHT_RATIO := 0.70


;------------------------------------------------------------------------------
; Cache Settings
;------------------------------------------------------------------------------

MAX_CACHE_SIZE := 200


;------------------------------------------------------------------------------
; User Interface
;------------------------------------------------------------------------------

SELECTION_COLOR := "0078D7"
NORMAL_COLOR    := "202020"


;==============================================================================
; Global Variables
;==============================================================================

;------------------------------------------------------------------------------
; Configuration Files
;------------------------------------------------------------------------------

global ConfigFile      := A_ScriptDir "\Settings.ini"
global IconFile        := A_ScriptDir "\monitor.ico"
global PauseIconFile   := A_ScriptDir "\monitor_pause.ico"
global LanguageFile    := A_ScriptDir "\Languages.ini"

global CurrentLanguage := "EN"


;------------------------------------------------------------------------------
; Program Data
;------------------------------------------------------------------------------

global Programs               := Map()
global ListRowToProgram       := Map()
global CheckedStartupWindows  := Map()


;------------------------------------------------------------------------------
; WinEvent Hooks
;------------------------------------------------------------------------------

global hookStart := 0
global hookEnd   := 0
global hookShow  := 0
global callback  := 0


;------------------------------------------------------------------------------
; GUI Objects
;------------------------------------------------------------------------------

global StatusGui        := 0
global SettingsGui      := 0
global SettingsListView := 0

global ProgramImageList := 0
global DefaultIconIndex := 0

global ratioWEdit         := 0
global ratioHEdit         := 0
global LanguageDropdown   := 0

global LangCache := Map()


;------------------------------------------------------------------------------
; Window Area Selection
;------------------------------------------------------------------------------

global areaWindowButton := 0
global areaClientButton := 0

global selectedArea := "WINDOW"

global positionTopLeftButton := 0
global positionCenterButton  := 0

global selectedPosition := "TOPLEFT"

; Button states are rendered directly by the custom controls.


;------------------------------------------------------------------------------
; Runtime State
;------------------------------------------------------------------------------

global paused      := false
global correcting  := false
global verifying   := false
global resizing    := false

global analyzing   := false


;------------------------------------------------------------------------------
; Resize Tracking
;------------------------------------------------------------------------------

global startW := 0
global startH := 0

global startWindowW := 0
global startWindowH := 0

global ResizeStart := Map()


;------------------------------------------------------------------------------
; Viewport Cache
;------------------------------------------------------------------------------

global ChildCache         := Map()
global ChildFailCount     := Map()
global ClientFailCount    := Map()

global LearnedChildClass  := Map()
global ProcessCache       := Map()

global StartupWindows     := Map()

global LearnedOffsets     := Map()
global PendingCalibration := Map()

global ScriptPID := DllCall("GetCurrentProcessId")


;------------------------------------------------------------------------------
; Window Selection
;------------------------------------------------------------------------------

global SelectingWindow  := false
global SelectedClickHwnd := 0


;------------------------------------------------------------------------------
; Settings Dialog
;------------------------------------------------------------------------------

global CurrentProgram := ""

global SettingsDirty    := false
global SettingsNeedSave := false

global SaveButton   := 0
global RemoveButton := 0

; NOTE:
; These variables are declared a second time in the original source.
; The duplicate declarations are intentionally kept to preserve the original
; structure. They can safely be removed in a later cleanup pass.

global areaWindowButton := 0
global areaClientButton := 0

global IgnoreControlEvents := false

global OriginalSettings := Map()

global SelectionGui    := 0
global SelectionFrames := Map()

global HoverButton := 0


;==============================================================================
; ChildFinder
;------------------------------------------------------------------------------
; Detects and evaluates child windows that may represent the application's
; primary rendering area.
;
; This class recursively scans the child window hierarchy and collects
; suitable viewport candidates for later evaluation.
;==============================================================================

class ChildFinder
{
    ; Returns the first child window of the specified parent window.
    static GetFirstChild(hwnd)
    {
        return DllCall("GetWindow", "Ptr", hwnd, "UInt", 5, "Ptr")
    }

    ; Returns the next sibling window.
    static GetNextChild(hwnd)
    {
        return DllCall("GetWindow", "Ptr", hwnd, "UInt", 2, "Ptr")
    }

    ; Analyzes all visible child windows and collects basic statistics.
    ;
    ; Returns:
    ;   Count - Number of visible child windows.
    ;   Area  - Combined area of all visible child windows.
    static AnalyzeChildren(hwnd)
    {
        childCount := 0
        childArea  := 0

        child := ChildFinder.GetFirstChild(hwnd)

        while child
        {
            if DllCall("IsWindowVisible", "Ptr", child)
            {
                try
                {
                    WinGetPos(&x, &y, &w, &h, "ahk_id " child)

                    if (w > 0 && h > 0)
                    {
                        childCount++
                        childArea += w * h
                    }
                }
            }

            child := ChildFinder.GetNextChild(child)
        }

        return {
            Count: childCount,
            Area:  childArea
        }
    }

    ; Recursively collects all visible child windows that are large enough
    ; to be considered viewport candidates.
    ;
    ; Each valid candidate is enriched with additional metadata that is
    ; later used by the viewport scoring algorithm.
    static CollectChildren(parentHwnd, program, parentW, parentH, &candidates, depth := 1)
    {
        child := ChildFinder.GetFirstChild(parentHwnd)

        while child
        {
            if DllCall("IsWindowVisible", "Ptr", child)
            {
                try
                {
                    WinGetPos(&x, &y, &w, &h, "ahk_id " child)

                    if (w >= 20 && h >= 20)
                    {
                        widthRatio  := w / parentW
                        heightRatio := h / parentH

                        if (widthRatio >= CHILD_MIN_WIDTH_RATIO
                            && heightRatio >= CHILD_MIN_HEIGHT_RATIO)
                        {
                            class := ""

                            try
                                class := WinGetClass("ahk_id " child)

                            if ChildFinder.IsIgnoredClass(class)
                            {
                                ChildFinder.CollectChildren(
                                    child,
                                    program,
                                    parentW,
                                    parentH,
                                    &candidates,
                                    depth + 1
                                )

                                child := ChildFinder.GetNextChild(child)
                                continue
                            }

                            analysis := ChildFinder.AnalyzeChildren(child)

                            candidates.Push({
                                Hwnd: child,
                                Class: class,
                                Depth: depth,

                                Preferred: HasProp(program, "PreferredClass")
                                    && StrLower(program.PreferredClass) = StrLower(class),

                                X: x,
                                Y: y,
                                Width: w,
                                Height: h,

                                ChildCount: analysis.Count,
                                ChildArea: analysis.Area
                            })
                        }
                    }
                }

                ChildFinder.CollectChildren(
                    child,
                    program,
                    parentW,
                    parentH,
                    &candidates,
                    depth + 1
                )
            }

            child := ChildFinder.GetNextChild(child)
        }
    }
	
	    ; Returns all viewport candidates for the specified parent window.
    static GetCandidates(parentHwnd, program)
    {
        candidates := []

        try
        {
            GetClientRectEx(
                parentHwnd,
                &dummyX,
                &dummyY,
                &parentW,
                &parentH
            )
        }
        catch
        {
            return candidates
        }

        ChildFinder.CollectChildren(
            parentHwnd,
            program,
            parentW,
            parentH,
            &candidates
        )

        return candidates
    }

    ; Returns true if one candidate is completely contained within another.
    static IsMostlyInside(inner, outer)
    {
        if (inner.Hwnd = outer.Hwnd)
            return false

        if (inner.X < outer.X)
            return false

        if (inner.Y < outer.Y)
            return false

        if (inner.X + inner.Width > outer.X + outer.Width)
            return false

        if (inner.Y + inner.Height > outer.Y + outer.Height)
            return false

        return true
    }

    ; Returns true if the specified window class should be ignored.
    static IsIgnoredClass(class)
    {
        switch StrLower(class)
        {
            case "button":
            case "static":
            case "scrollbar":
            case "toolbarwindow32":
            case "rebarwindow32":
            case "msctls_statusbar32":
            case "sysheader32":
            case "combobox":
            case "edit":
            case "listbox":
            case "richedit":
            case "richedit20w":
                return true
        }

        return false
    }

    ; Calculates the score used to rank viewport candidates.
    static CalculateScore(parentW, parentH, candidate)
    {
        score := 0

        ;----------------------------------------------------------------------
        ; Relative area
        ;----------------------------------------------------------------------

        parentArea := parentW * parentH

        if (parentArea > 0)
        {
            area := candidate.Width * candidate.Height
            score += Round((area / parentArea) * 1000)
        }

        ;----------------------------------------------------------------------
        ; Distance from the parent window center
        ;----------------------------------------------------------------------

        parentCenterX := parentW / 2
        parentCenterY := parentH / 2

        centerX := candidate.X + candidate.Width / 2
        centerY := candidate.Y + candidate.Height / 2

        score -= Round(Abs(centerX - parentCenterX) / 8)
        score -= Round(Abs(centerY - parentCenterY) / 8)

        ;----------------------------------------------------------------------
        ; Bonus for candidates that nearly match the parent size
        ;----------------------------------------------------------------------

        if (candidate.Width >= parentW * 0.95)
            score += 200

        if (candidate.Height >= parentH * 0.95)
            score += 200

        ;----------------------------------------------------------------------
        ; Aspect ratio similarity
        ;----------------------------------------------------------------------

        parentRatio := parentW / parentH
        childRatio := candidate.Width / candidate.Height

        diff := Abs(parentRatio - childRatio)

        score += Max(0, 150 - Round(diff * 300))

        ;----------------------------------------------------------------------
        ; Penalize narrow controls
        ;----------------------------------------------------------------------

        if (candidate.Width < parentW * 0.40)
            score -= 300

        if (candidate.Height < parentH * 0.40)
            score -= 300

        ;----------------------------------------------------------------------
        ; Prefer previously learned window classes
        ;----------------------------------------------------------------------

        if (candidate.Preferred)
            score += 5000

        ;----------------------------------------------------------------------
        ; Window class bonuses
        ;----------------------------------------------------------------------

        switch StrLower(candidate.Class)
        {
            case "chrome_renderwidgethosthwnd":
                score += 800

            case "chrome_widgetwin_0":
            case "chrome_widgetwin_1":
                score += 300

            case "mediatek":
                score += 400

            case "qt5qwindowicon":
            case "qt6qwindowicon":
                score += 300

            case "unitycontainerwndclass":
                score += 600

            case "sdl_app":
                score += 500
        }

        ;----------------------------------------------------------------------
        ; Overlay detection
        ;----------------------------------------------------------------------

        if (candidate.Y > parentH * 0.70
            && candidate.Height < parentH * 0.35)
            score -= 500

        if (candidate.Y = 0
            && candidate.Height < parentH * 0.25)
            score -= 400

        if (candidate.X > parentW * 0.70
            && candidate.Width < parentW * 0.30)
            score -= 400

        if (candidate.X = 0
            && candidate.Width < parentW * 0.30)
            score -= 400

        ;----------------------------------------------------------------------
        ; Window tree depth
        ;----------------------------------------------------------------------

        if (candidate.Depth = 2)
            score += 75
        else if (candidate.Depth = 3)
            score += 150
        else if (candidate.Depth >= 4)
            score += 100

        ;----------------------------------------------------------------------
        ; Candidate relationships
        ;----------------------------------------------------------------------

        ; Bonus for candidates containing other candidates.
        score += candidate.ContainsCount * 40

        ; Penalty for candidates contained within other candidates.
        score -= candidate.InsideCount * 60

        ;----------------------------------------------------------------------
        ; Child window statistics
        ;----------------------------------------------------------------------

        if (candidate.ChildCount > 0)
            score += Min(candidate.ChildCount * 10, 80)

        area := candidate.Width * candidate.Height

        if (area > 0)
        {
            coverage := candidate.ChildArea / area

            ; Values above 1 may occur due to overlapping child windows.
            coverage := Min(coverage, 1.0)

            ; Slightly favor container windows without allowing them to
            ; outrank dedicated rendering windows.
            score += Round(coverage * 80)
        }

        return score
    }

}

class ProgramAnalyzer
{
    ; Increment this value whenever the analysis logic changes.
    ; Programs will automatically be re-analyzed if required.
    static CurrentVersion := 1

    ; Checks whether the specified program requires a new analysis.
    static Check(program)
    {
        global Programs

        if !Programs.Has(program)
            return

        data := Programs[program]

        ; Only CLIENT mode requires viewport analysis.
        if (data.Area != "CLIENT")
            return

        ; Skip if the current analysis version is already available.
        if (HasProp(data, "AnalysisVersion")
            && data.AnalysisVersion >= ProgramAnalyzer.CurrentVersion)
        {
            return
        }

        ProgramAnalyzer.Start(program)
    }

    ; Performs the viewport analysis for the specified program.
    static Start(program)
    {
        global analyzing, Programs

        analyzing := true

        hwnd := WinExist("ahk_exe " program)

        if !hwnd
        {
            analyzing := false
            return
        }

        data := Programs[program]

        viewport := ViewportResolver.Resolve(
            hwnd,
            program,
            data
        )

        if !viewport
        {
            analyzing := false
            return
        }

        targetHwnd := viewport.Hwnd

        ; Collect information about the resolved viewport.
        viewportData := ProgramAnalyzer.MeasureViewport(targetHwnd)

        ; Analyze all child windows of the resolved viewport.
        children := ProgramAnalyzer.AnalyzeChildWindows(targetHwnd)


        ; ==================================================
        ; ANALYSIS PLACEHOLDER
        ; ==================================================
        ; Future viewport analysis logic should be implemented here.
        ; The current code only collects the required data.


        ; Debug output
        ;MsgBox(
        ;    "Analysis started:`n`n"
        ;    program
        ;    "`nHWND: " hwnd
        ;    "`nAnalysis Window: " targetHwnd
        ;    "`nWindow HWND: " hwnd
        ;    "`nViewport: "
        ;    viewportData.Width "x" viewportData.Height
        ;    "`n`nDetected Children: " children.Length
        ;)

        ;for child in children
        ;{
        ;    MsgBox(
        ;        "Child HWND: " child.Hwnd
        ;        "`nClass: " child.Class
        ;        "`nSize: " child.Width "x" child.Height
        ;        "`nPosition: " child.X "," child.Y
        ;    )
        ;}

        ; Mark analysis as completed.
        Programs[program].AnalysisPending := false
        Programs[program].AnalysisVersion := ProgramAnalyzer.CurrentVersion

        analyzing := false
    }
	
    ; Measures the client area of the specified viewport window.
    static MeasureViewport(hwnd)
    {
        data := {}

        x := 0
        y := 0
        w := 0
        h := 0

        GetClientRectEx(
            hwnd,
            &x,
            &y,
            &w,
            &h
        )

        data.X := x
        data.Y := y
        data.Width := w
        data.Height := h

        return data
    }

    ; Collects information about all direct child windows.
    static AnalyzeChildWindows(hwnd)
    {
        result := []

        try
        {
            children := WinGetList("ahk_parent " hwnd)

            for childHwnd in children
            {
                try
                {
                    class := WinGetClass("ahk_id " childHwnd)

                    WinGetPos(
                        &x,
                        &y,
                        &w,
                        &h,
                        "ahk_id " childHwnd
                    )

                    result.Push({
                        Hwnd: childHwnd,
                        Class: class,
                        X: x,
                        Y: y,
                        Width: w,
                        Height: h
                    })
                }
            }
        }

        return result
    }

}

; ==========================================================
; CLASS: ViewportResolver
; ==========================================================
; Resolves the viewport used for ratio calculations.
; Depending on the program configuration, the viewport can be
; either the entire window or a detected client/render window.

class ViewportResolver
{
    ; Creates a new viewport object with default values.
    static CreateViewport(parentHwnd)
    {
        return {
            Hwnd: parentHwnd,

            Source: "PARENT",
            Strategy: "",

            X: 0,
            Y: 0,
            Width: 0,
            Height: 0,

            OffsetTop: 0,
            OffsetBottom: 0,
            OffsetLeft: 0,
            OffsetRight: 0,

            Confidence: 0,
            Valid: false,
            Class: "",
            Diagnostics: Map()
        }
    }

    ; Creates a deep copy of a viewport object.
    static CloneViewport(viewport)
    {
        copy := {}

        for key, value in viewport.OwnProps()
        {
            if IsObject(value)
                copy.%key% := value.Clone()
            else
                copy.%key% := value
        }

        return copy
    }

    ; Returns the cached viewport entry for the specified parent window.
    static GetCacheEntry(parentHwnd)
    {
        global ChildCache

        if !ChildCache.Has(parentHwnd)
            return false

        return ChildCache[parentHwnd]
    }

    ; Removes the cached viewport entry for the specified parent window.
    static RemoveCacheEntry(parentHwnd)
    {
        global ChildCache

        if ChildCache.Has(parentHwnd)
            ChildCache.Delete(parentHwnd)
    }

    ; Resolves the viewport according to the configured capture mode.
    static Resolve(parentHwnd, process, program)
    {
        result := ViewportResolver.CreateViewport(parentHwnd)

        GetClientRectEx(
            parentHwnd,
            &parentX,
            &parentY,
            &parentW,
            &parentH
        )

        if (program.Area != "CLIENT")
            return ViewportResolver.ResolveWindow(result)

        return ViewportResolver.ResolveClient(
            parentHwnd,
            process,
            program,
            parentW,
            parentH,
            result
        )
    }

    ; Uses the parent window itself as the viewport.
    static ResolveWindow(result)
    {
        result.Source := "WINDOW"
        result.Strategy := "Window"
        result.Confidence := 100

        return ViewportResolver.Measure(result)
    }

    ; Resolves a client viewport and applies configured offsets.
    static ResolveClient(parentHwnd, process, program, parentW, parentH, result)
    {
        offsets := ViewportResolver.GetOffsets(program)

        result.OffsetTop := offsets.Top
        result.OffsetBottom := offsets.Bottom
        result.OffsetLeft := offsets.Left
        result.OffsetRight := offsets.Right

        return ViewportResolver.ResolveViewport(
            parentHwnd,
            process,
            program,
            parentW,
            parentH,
            result
        )
    }
	
	    ; Tries all available viewport detection strategies in priority order.
    static TryStrategies(parentHwnd, process, program, parentW, parentH, result)
    {
        viewport := ViewportResolver.TryCachedViewport(
            parentHwnd,
            process,
            program,
            parentW,
            parentH,
            result
        )

        if IsObject(viewport)
            return viewport

        viewport := ViewportResolver.TryPreferredClass(
            parentHwnd,
            process,
            program,
            parentW,
            parentH,
            result
        )

        if IsObject(viewport)
            return viewport

        viewport := ViewportResolver.FindBestViewport(
            parentHwnd,
            process,
            program,
            parentW,
            parentH,
            result
        )

        if IsObject(viewport)
            return viewport

        return false
    }

    ; Resolves the viewport or falls back to the parent window.
    static ResolveViewport(parentHwnd, process, program, parentW, parentH, result)
    {
        viewport := ViewportResolver.TryStrategies(
            parentHwnd,
            process,
            program,
            parentW,
           	parentH,
            result
        )

        if IsObject(viewport)
            return viewport

        return ViewportResolver.ResolveParentViewport(result)
    }

    ; Measures the client area of the resolved viewport.
    static Measure(viewport)
    {
        x := 0
        y := 0
        w := 0
        h := 0

        GetClientRectEx(
            viewport.Hwnd,
            &x,
            &y,
            &w,
            &h
        )

        viewport.X := x
        viewport.Y := y
        viewport.Width := w
        viewport.Height := h

        viewport := ViewportResolver.ApplyOffsets(viewport)
        viewport.Valid := (viewport.Width > 0 && viewport.Height > 0)

        return viewport
    }

    ; Applies the configured viewport offsets.
    static ApplyOffsets(viewport)
    {
        viewport.X += viewport.OffsetLeft
        viewport.Y += viewport.OffsetTop

        viewport.Width -= viewport.OffsetLeft
        viewport.Width -= viewport.OffsetRight

        viewport.Height -= viewport.OffsetTop
        viewport.Height -= viewport.OffsetBottom

        viewport.Width := Max(0, viewport.Width)
        viewport.Height := Max(0, viewport.Height)

        return viewport
    }

    ; Returns the configured viewport offsets for the program.
    static GetOffsets(program)
    {
        return {
            Top: HasProp(program, "OffsetTop") ? program.OffsetTop : 0,
            Bottom: HasProp(program, "OffsetBottom") ? program.OffsetBottom : 0,
            Left: HasProp(program, "OffsetLeft") ? program.OffsetLeft : 0,
            Right: HasProp(program, "OffsetRight") ? program.OffsetRight : 0
        }
    }

    ; Determines whether two viewport descriptions refer to the same window.
    static IsSameViewport(old, current)
    {
        if (old.Class != current.Class)
            return false

        if (Abs(old.Width - current.Width) > 4)
            return false

        if (Abs(old.Height - current.Height) > 4)
            return false

        if (Abs(old.X - current.X) > 4)
            return false

        if (Abs(old.Y - current.Y) > 4)
            return false

        return true
    }

    ; Attempts to reuse a previously cached viewport.
    static TryCachedViewport(parentHwnd, process, program, parentW, parentH, result)
    {
        cached := ViewportResolver.GetCacheEntry(parentHwnd)

        if !IsObject(cached)
            return false

        if !DllCall("IsWindow", "Ptr", cached.Hwnd)
        {
            ViewportResolver.RemoveCacheEntry(parentHwnd)
            return false
        }

        current := {
            Hwnd: cached.Hwnd,
            Class: cached.Class
        }

        x := 0
        y := 0
        w := 0
        h := 0

        GetClientRectEx(
            cached.Hwnd,
            &x,
            &y,
            &w,
            &h
        )

        current.X := x
        current.Y := y
        current.Width := w
        current.Height := h

        if !ViewportResolver.IsSameViewport(cached, current)
        {
            ViewportResolver.RemoveCacheEntry(parentHwnd)
            return false
        }

        cached.OffsetTop := result.OffsetTop
        cached.OffsetBottom := result.OffsetBottom
        cached.OffsetLeft := result.OffsetLeft
        cached.OffsetRight := result.OffsetRight

        return ViewportResolver.CloneViewport(cached)
    }
	
	    ; Attempts to locate a viewport using the program's preferred window class.
    static TryPreferredClass(parentHwnd, process, program, parentW, parentH, result)
    {
        if !HasProp(program, "PreferredClass")
            return false

        preferredClass := program.PreferredClass

        if (preferredClass = "")
            return false

        candidates := ChildFinder.GetCandidates(parentHwnd, program)

        for candidate in candidates
        {
            if (candidate.Class != preferredClass)
                continue

            candidate := ViewportResolver.MeasureCandidate(candidate)

            candidate.Strategy := "PreferredClass"
            candidate.Confidence := 95

            return ViewportResolver.AcceptCandidate(
                parentHwnd,
                process,
                candidate,
                result
            )
        }

        return false
    }

    ; Accepts the selected candidate and stores it in the cache.
    static AcceptCandidate(parentHwnd, process, candidate, result)
    {
        viewport := ViewportResolver.BuildViewportFromCandidate(
            result,
            candidate
        )

        ViewportResolver.CacheViewport(
            parentHwnd,
            process,
            viewport
        )

        return viewport
    }

    ; Falls back to using the parent window's client area.
    static ResolveParentViewport(result)
    {
        result.Source := "PARENT"
        result.Strategy := "ParentClient"
        result.Confidence := 60

        return ViewportResolver.Measure(result)
    }

    ; Returns the score bonus for a matching preferred window class.
    static CalculatePreferredClassBonus(candidate, preferredClass)
    {
        if (preferredClass = "")
            return 0

        if (candidate.Class != preferredClass)
            return 0

        return 1000
    }

    ; Calculates the final score for a viewport candidate.
    static CalculateCandidateScore(parentW, parentH, candidate, preferredClass)
    {
        score := ChildFinder.CalculateScore(
            parentW,
            parentH,
            candidate
        )

        score += ViewportResolver.CalculatePreferredClassBonus(
            candidate,
            preferredClass
        )

        return score
    }

    ; Evaluates all candidates and assigns a score to each one.
    static EvaluateCandidates(candidates, parentW, parentH, preferredClass)
    {
        ; Reset relationship counters.
        for candidate in candidates
        {
            candidate.ContainsCount := 0
            candidate.InsideCount := 0
        }

        ; Determine containment relationships between candidates.
        for outer in candidates
        {
            for inner in candidates
            {
                if ChildFinder.IsMostlyInside(inner, outer)
                {
                    outer.ContainsCount++
                    inner.InsideCount++
                }
            }
        }

        ; Calculate the final score for every candidate.
        for candidate in candidates
        {
            candidate.Score := ViewportResolver.CalculateCandidateScore(
                parentW,
                parentH,
                candidate,
                preferredClass
            )
        }

        return candidates
    }

    ; Returns the candidate with the highest score.
    static SelectHighestScore(candidates)
    {
        best := 0
        bestScore := -1

        for candidate in candidates
        {
            if (candidate.Score > bestScore)
            {
                bestScore := candidate.Score
                best := candidate
            }
        }

        return best
    }

    ; Selects the best viewport candidate for the current window.
    static SelectBestCandidate(candidates, program, parentW, parentH)
    {
        preferredClass := ""

        if HasProp(program, "PreferredClass")
            preferredClass := program.PreferredClass

        candidates := ViewportResolver.EvaluateCandidates(
            candidates,
            parentW,
            parentH,
            preferredClass
        )

        return ViewportResolver.SelectHighestScore(candidates)
    }
	
	    ; Measures the client geometry of a viewport candidate.
    static MeasureCandidateGeometry(candidate)
    {
        x := 0
        y := 0
        w := 0
        h := 0

        GetClientRectEx(
            candidate.Hwnd,
            &x,
            &y,
            &w,
            &h
        )

        return {
            X: x,
            Y: y,
            Width: w,
            Height: h
        }
    }

    ; Creates a viewport object from the selected candidate.
    static BuildViewportFromCandidate(result, candidate)
    {
        result.Hwnd := candidate.Hwnd
        result.Class := candidate.Class

        result.Source := "CHILD"
        result.Strategy := candidate.Strategy
        result.Confidence := candidate.Confidence

        result.X := candidate.X
        result.Y := candidate.Y
        result.Width := candidate.Width
        result.Height := candidate.Height

        result.Valid := (result.Width > 0 && result.Height > 0)

        return ViewportResolver.ApplyOffsets(result)
    }

    ; Updates a candidate with its current client geometry.
    static MeasureCandidate(candidate)
    {
        measurement := ViewportResolver.MeasureCandidateGeometry(candidate)

        candidate := ViewportResolver.CreateCandidate(candidate)

        candidate.X := measurement.X
        candidate.Y := measurement.Y
        candidate.Width := measurement.Width
        candidate.Height := measurement.Height

        return candidate
    }

    ; Retrieves all viewport candidates for the specified parent window.
    static FindCandidates(parentHwnd, program)
    {
        return ChildFinder.GetCandidates(
            parentHwnd,
            program
        )
    }

    ; Creates a normalized candidate object.
    static CreateCandidate(candidate)
    {
        return {
            Hwnd: candidate.Hwnd,
            Class: candidate.Class,

            X: candidate.X,
            Y: candidate.Y,
            Width: candidate.Width,
            Height: candidate.Height,

            Depth: candidate.Depth,

            ChildCount: candidate.ChildCount,
            ChildArea: candidate.ChildArea,

            ContainsCount: HasProp(candidate, "ContainsCount")
                ? candidate.ContainsCount : 0,

            InsideCount: HasProp(candidate, "InsideCount")
                ? candidate.InsideCount : 0,

            Score: HasProp(candidate, "Score")
                ? candidate.Score : 0,

            Strategy: "BestChild",
            Confidence: 90,
            Diagnostics: Map()
        }
    }

    ; Stores the resolved viewport in the cache.
    static CacheViewport(parentHwnd, process, viewport)
    {
        global ChildCache

        ChildCache[parentHwnd] := ViewportResolver.CloneViewport(viewport)

        ; Remember the detected class for future resolutions.
        if (viewport.Class != "")
            RememberPreferredClass(process, viewport.Class)
    }

    ; Finds and accepts the best available viewport candidate.
    static FindBestViewport(parentHwnd, process, program, parentW, parentH, result)
    {
        candidate := ViewportResolver.DetectBestCandidate(
            parentHwnd,
            program,
            parentW,
            parentH
        )

        if !IsObject(candidate)
            return false

        candidate := ViewportResolver.MeasureCandidate(candidate)

        return ViewportResolver.AcceptCandidate(
            parentHwnd,
            process,
            candidate,
            result
        )
    }

    ; Detects the highest-ranked viewport candidate.
    static DetectBestCandidate(parentHwnd, program, parentW, parentH)
    {
        candidates := ViewportResolver.FindCandidates(
            parentHwnd,
            program
        )

        candidate := ViewportResolver.SelectBestCandidate(
            candidates,
            program,
            parentW,
            parentH
        )

        return candidate
    }

    ; Handles a failed client viewport resolution.
    ; The correction routine is executed only once per process.
    static HandleClientFailure(hwnd, process)
    {
        global ClientFailCount

        count := 0

        if ClientFailCount.Has(process)
            count := ClientFailCount[process]

        count++
        ClientFailCount[process] := count

        if (count > 1)
            return

        FixRatio(hwnd, process)
    }

    ; Clears the client failure counter for the specified process.
    static ResetClientFailures(process)
    {
        global ClientFailCount

        if ClientFailCount.Has(process)
            ClientFailCount.Delete(process)
    }

}

; ==========================================================
; CLASS: CacheManager
; ==========================================================
; Provides simple cache management helpers.
; The cache size is limited to prevent uncontrolled memory growth.
; Since Map objects are unordered, a full cache reset is used instead
; of an LRU (Least Recently Used) eviction strategy.

class CacheManager
{
    ; ------------------------------------------------------
    ; Stores a value in the specified cache.
    ; Clears the cache first if the maximum size is reached.
    ; ------------------------------------------------------
    static Set(map, key, value)
    {
        if (map.Count >= MAX_CACHE_SIZE)
        {
            ; Maps are unordered, therefore a simple reset is used
            ; instead of an LRU eviction algorithm.
            map.Clear()
        }

        map[key] := value
    }

    ; ------------------------------------------------------
    ; Returns the cached value for the specified key.
    ; Returns an empty string if the key does not exist.
    ; ------------------------------------------------------
    static Get(map, key)
    {
        return map.Has(key) ? map[key] : ""
    }
}


; ==========================================================
; SCRIPT INITIALIZATION
; ==========================================================

Persistent

A_IconTip := "WindowRatioLock"

; Register tray message handler.
OnMessage(0x404, TrayClick)

; Load configuration and language resources.
LoadSettings()
LoadLanguage()

; Create the user interface.
CreateStatusGui()
CreateTrayMenu()

; Initialize tray icon.
SetTimer(UpdateTrayIcon, -50)

; Reset startup tracking.
StartupWindows.Clear()
CheckedStartupWindows.Clear()

; Perform delayed startup window detection.
SetTimer(CheckStartupWindows, -1000)

UpdateTrayIcon()


; ==========================================================
; TRAY ICON
; ==========================================================

; Updates the tray icon depending on the current pause state.
UpdateTrayIcon()
{
    global paused, IconFile, PauseIconFile

    if (paused && FileExist(PauseIconFile))
    {
        TraySetIcon(PauseIconFile)
        return
    }

    if FileExist(IconFile)
        TraySetIcon(IconFile)
}


; ==========================================================
; PROGRAM ICONS
; ==========================================================

; Returns the executable icon path of a configured program.
; Returns an empty string if no valid path is available.
GetProgramIcon(data)
{
    try
    {
        if !data.HasOwnProp("Path") || (data.Path = "")
            return ""

        if FileExist(data.Path)
            return data.Path
    }
    catch
    {
    }

    return ""
}

; Converts an executable filename into a readable display name.
; Example:
;   notepad.exe  -> Notepad
DisplayProgramName(name)
{
    SplitPath(name, , , , &nameNoExt)

    if (nameNoExt = "")
        return ""

    return StrUpper(SubStr(nameNoExt, 1, 1)) . SubStr(nameNoExt, 2)
}


; ==========================================================
; STATUS GUI
; ==========================================================

; Creates the floating status window used to display
; short informational messages.
CreateStatusGui()
{
    global StatusGui

    if IsObject(StatusGui)
        return

    StatusGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x40000", "WindowRatioLock")
    StatusGui.BackColor := "202020"

    statusText := StatusGui.AddText("cFFFFFF w300 h50 Center", "")
    statusText.SetFont("s12 bold", "Segoe UI")

    ; Store a reference for quick access.
    StatusGui.StatusText := statusText
}

; Displays a temporary status message.
ShowStatus(text)
{
    global StatusGui

    if !IsObject(StatusGui)
        CreateStatusGui()

    StatusGui.StatusText.Text := text
    StatusGui.Show("NoActivate AutoSize Center")

    ; Ensure the window remains on top.
    WinSetAlwaysOnTop(true, "ahk_id " StatusGui.Hwnd)

    SetTimer(HideStatusGui, -1500)
}

; Hides the status window.
HideStatusGui()
{
    global StatusGui

    try
        StatusGui.Hide()
}

; Resets the displayed status text to the default value.
ClearStatus()
{
    global StatusGui

    if IsObject(StatusGui) && IsObject(StatusGui.StatusText)
        StatusGui.StatusText.Text := "Bereit"
}

; ==========================================================
; TRAY MENU
; ==========================================================

; Creates and initializes the tray menu.
CreateTrayMenu()
{
    A_TrayMenu.Delete()

    A_TrayMenu.Add()
    A_TrayMenu.Add(Lang("TrayOpenSettings"), OpenSettings)
    A_TrayMenu.Add(Lang("TrayAddProgram"), AddCurrentWindow)

    A_TrayMenu.Add()

    A_TrayMenu.Add(Lang("TrayPause"), TogglePause)

    if paused
        A_TrayMenu.Rename(Lang("TrayPause"), Lang("TrayResume"))

    A_TrayMenu.Add()

    if StartupEnabled()
        A_TrayMenu.Add(Lang("TrayDisableStartup"), DisableStartup)
    else
        A_TrayMenu.Add(Lang("TrayEnableStartup"), EnableStartup)

    A_TrayMenu.Add()
    A_TrayMenu.Add(Lang("TrayExit"), ExitScript)
}


; ==========================================================
; LANGUAGE SYSTEM
; ==========================================================

; Loads the configured language from the settings file.
; Falls back to German if the language code is invalid.
LoadLanguage()
{
    global ConfigFile, CurrentLanguage

    CurrentLanguage := IniRead(
        ConfigFile,
        "General",
        "Language",
        "DE"
    )

    if (
        CurrentLanguage != "DE"
        && CurrentLanguage != "EN"
        && CurrentLanguage != "FR"
        && CurrentLanguage != "ES"
        && CurrentLanguage != "IT"
        && CurrentLanguage != "NL"
        && CurrentLanguage != "PL"
        && CurrentLanguage != "PT-BR"
        && CurrentLanguage != "TR"
        && CurrentLanguage != "RU"
        && CurrentLanguage != "JA"
        && CurrentLanguage != "KO"
        && CurrentLanguage != "ZH-CN"
        && CurrentLanguage != "CS"
        && CurrentLanguage != "SV"
        && CurrentLanguage != "UK"
        && CurrentLanguage != "HU"
        && CurrentLanguage != "RO"
        && CurrentLanguage != "EL"
        && CurrentLanguage != "DA"
        && CurrentLanguage != "FI"
        && CurrentLanguage != "NO"
    )
    {
        CurrentLanguage := "DE"
    }
}

; Returns the localized string for the specified key.
; Values are cached to avoid repeatedly parsing the language file.
Lang(key)
{
    global LanguageFile, CurrentLanguage

    if LangCache.Has(CurrentLanguage "|" key)
        return LangCache[CurrentLanguage "|" key]

    text := FileRead(
        LanguageFile,
        "UTF-8"
    )

    section := false

    for line in StrSplit(text, "`n")
    {
        line := Trim(line, " `t`r`n" Chr(0xFEFF))

        if (line = "[" CurrentLanguage "]")
        {
            section := true
            continue
        }

        if section
        {
            if RegExMatch(line, "^\[(.*)\]$")
                break

            if InStr(line, key "=")
            {
                parts := StrSplit(line, "=", 2)

                if (parts.Length = 2 && parts[1] = key)
                {
                    value := parts[2]
                    LangCache[CurrentLanguage "|" key] := value
                    return value
                }
            }
        }
    }

    ; Fallback: return the key itself if no translation exists.
    return key
}

; Clears the language string cache.
LangClearCache()
{
    global LangCache

    LangCache.Clear()
}

; Changes the current language and stores it in the settings file.
SetLanguage(language)
{
    global ConfigFile, CurrentLanguage

    if (
        language != "DE"
        && language != "EN"
        && language != "FR"
        && language != "ES"
        && language != "IT"
        && language != "NL"
        && language != "PL"
        && language != "PT-BR"
        && language != "TR"
        && language != "RU"
        && language != "JA"
        && language != "KO"
        && language != "ZH-CN"
        && language != "CS"
        && language != "SV"
        && language != "UK"
        && language != "HU"
        && language != "RO"
        && language != "EL"
        && language != "DA"
        && language != "FI"
        && language != "NO"
    )
        return

    CurrentLanguage := language

    IniWrite(
        CurrentLanguage,
        ConfigFile,
        "General",
        "Language"
    )
}


; ==========================================================
; AUTOMATIC FONT SCALING
; ==========================================================

; Adjusts the font size of a button based on its visible text length.
AutoButtonFont(ctrl, text)
{
    visible := RegExReplace(text, "^[^\n]*\n")

    len := StrLen(visible)

    size := 14

    if (len >= 8)
        size := 12

    if (len >= 9)
        size := 11

    if (len >= 11)
        size := 10

    if (len >= 22)
        size := 9

    ctrl.SetFont("s" size, "Segoe UI")
    ctrl.Text := text
}

; Adjusts the font size of a control based on its text length.
AutoControlFont(ctrl, text)
{
    len := StrLen(text)

    size := 14

    if (len >= 18)
        size := 13

    if (len >= 19)
        size := 12

    if (len >= 21)
        size := 11

    if (len >= 28)
        size := 9

    ctrl.SetFont("s" size, "Segoe UI")
    ctrl.Text := text
}


; ==========================================================
; SETTINGS
; ==========================================================
; Loads and stores all program-specific settings.

; Loads the complete configuration from the settings file.
LoadSettings()
{
    global ConfigFile, Programs, paused

    ; Restore global pause state.
    paused := IniRead(ConfigFile, "General", "Paused", 0) = 1

    ; Create the configuration file structure if necessary.
    if !FileExist(ConfigFile)
        IniWrite(0, ConfigFile, "Programs", "Count")

    count := IniRead(ConfigFile, "Programs", "Count", 0)

    Loop count
    {
        section := "Program" A_Index

        name := IniRead(ConfigFile, section, "Name", "")

        if (name = "")
            continue

        Programs[name] := {
            Path: IniRead(ConfigFile, section, "Path", ""),
            RatioW: Max(1, Integer(IniRead(ConfigFile, section, "RatioW", "16"))),
            RatioH: Max(1, Integer(IniRead(ConfigFile, section, "RatioH", "9"))),
            Position: IniRead(ConfigFile, section, "Position", "TOPLEFT"),
            Area: IniRead(ConfigFile, section, "Area", "WINDOW"),

            OffsetTop: Integer(IniRead(ConfigFile, section, "OffsetTop", 0)),
            OffsetBottom: Integer(IniRead(ConfigFile, section, "OffsetBottom", 0)),
            OffsetLeft: Integer(IniRead(ConfigFile, section, "OffsetLeft", 0)),
            OffsetRight: Integer(IniRead(ConfigFile, section, "OffsetRight", 0)),

            PreferredClass: IniRead(ConfigFile, section, "PreferredClass", ""),

            AnalysisPending: IniRead(ConfigFile, section, "AnalysisPending", 0) = 1,
            AnalysisVersion: Integer(IniRead(ConfigFile, section, "AnalysisVersion", 0))
        }
    }
}

; Saves the current configuration to the settings file.
SaveSettings()
{
    global ConfigFile, Programs

    ; Remove all existing program sections before rebuilding them.
    Loop 1000
    {
        try
        {
            IniDelete(ConfigFile, "Program" A_Index)
        }
        catch
        {
        }
    }

    index := 1

    for name, data in Programs
    {
        section := "Program" index

        IniWrite(name, ConfigFile, section, "Name")
        IniWrite(data.Path, ConfigFile, section, "Path")

        IniWrite(data.RatioW, ConfigFile, section, "RatioW")
        IniWrite(data.RatioH, ConfigFile, section, "RatioH")

        IniWrite(data.Position, ConfigFile, section, "Position")
        IniWrite(data.Area, ConfigFile, section, "Area")

        IniWrite(data.OffsetTop, ConfigFile, section, "OffsetTop")
        IniWrite(data.OffsetBottom, ConfigFile, section, "OffsetBottom")
        IniWrite(data.OffsetLeft, ConfigFile, section, "OffsetLeft")
        IniWrite(data.OffsetRight, ConfigFile, section, "OffsetRight")

        IniWrite(data.PreferredClass, ConfigFile, section, "PreferredClass")

        IniWrite(
            HasProp(data, "AnalysisPending") ? data.AnalysisPending : 0,
            ConfigFile,
            section,
            "AnalysisPending"
        )

        IniWrite(
            HasProp(data, "AnalysisVersion") ? data.AnalysisVersion : 0,
            ConfigFile,
            section,
            "AnalysisVersion"
        )

        index++
    }

    ; Store the number of configured programs.
    IniWrite(Programs.Count, ConfigFile, "Programs", "Count")
}


; ==========================================================
; PROGRAM SETTINGS
; ==========================================================

; Ensures that all required settings exist for the specified program.
; Missing properties are added automatically and persisted.
EnsureProgramDefaults(process)
{
    global Programs

    if !Programs.Has(process)
        return

    data := Programs[process]

    defaults := Map(
        "OffsetTop", 0,
        "OffsetBottom", 0,
        "OffsetLeft", 0,
        "OffsetRight", 0,
        "PreferredClass", ""
    )

    changed := false

    for key, value in defaults
    {
        if !HasProp(data, key)
        {
            data.%key% := value
            changed := true
        }
    }

    if changed
    {
        Programs[process] := data
        SaveSettings()
    }
}

; Marks the configuration for delayed saving.
; Multiple changes within a short time are combined into a single write.
MarkSettingsForSave()
{
    global SettingsNeedSave

    if SettingsNeedSave
        return

    SettingsNeedSave := true

    SetTimer(FlushSettings, -1000)
}

; Writes pending configuration changes to disk.
FlushSettings()
{
    global SettingsNeedSave

    if !SettingsNeedSave
        return

    SettingsNeedSave := false
    SaveSettings()
}

; Learns the preferred viewport class for a program.
; A class must be detected multiple times before it is stored.
RememberPreferredClass(process, className)
{
    global Programs
    global LearnedChildClass

    if (className = "")
        return

    if !Programs.Has(process)
        return

    if !LearnedChildClass.Has(process)
    {
        LearnedChildClass[process] := {
            Class: className,
            Count: 1
        }
        return
    }

    learned := LearnedChildClass[process]

    if (learned.Class != className)
    {
        learned.Class := className
        learned.Count := 1
        LearnedChildClass[process] := learned
        return
    }

    learned.Count++
    LearnedChildClass[process] := learned

    ; Require multiple confirmations before accepting the class.
    if (learned.Count < 3)
        return

    data := Programs[process]

    ; Never overwrite an existing manually or previously learned class.
    if (HasProp(data, "PreferredClass")
        && data.PreferredClass != "")
    {
        return
    }

    data.PreferredClass := className
    Programs[process] := data

    MarkSettingsForSave()
}

; Resets all learned viewport information for the specified program.
RecoverViewport(process)
{
    global Programs
    global LearnedChildClass
    global LearnedOffsets
    global ChildCache

    if !Programs.Has(process)
        return false

    data := Programs[process]

    ; Reset stored viewport configuration.
    data.PreferredClass := ""

    data.OffsetTop := 0
    data.OffsetBottom := 0
    data.OffsetLeft := 0
    data.OffsetRight := 0

    Programs[process] := data

    ; Remove learned child class.
    if LearnedChildClass.Has(process)
        LearnedChildClass.Delete(process)

    ; Remove learned offsets.
    if LearnedOffsets.Has(process)
        LearnedOffsets.Delete(process)

    ; Clear the viewport cache.
    ChildCache.Clear()

    MarkSettingsForSave()

    return true
}

; ----------------------------------------------------------
; Learns viewport offsets by comparing the parent viewport
; with the detected child viewport.
; Stable values are only stored after multiple identical
; measurements to avoid incorrect calibration.
; ----------------------------------------------------------
CalibrateOffsets(process, parentViewport, childViewport)
{
    global Programs
    global LearnedOffsets

    if !Programs.Has(process)
        return

    left := childViewport.X - parentViewport.X
    top := childViewport.Y - parentViewport.Y

    right :=
        (parentViewport.X + parentViewport.Width)
        - (childViewport.X + childViewport.Width)

    bottom :=
        (parentViewport.Y + parentViewport.Height)
        - (childViewport.Y + childViewport.Height)

    ; Reject invalid measurements.
    if (
        left < 0
        || top < 0
        || right < 0
        || bottom < 0
    )
        return

    ; Reject unrealistic offset values.
    if (
        left > 150
        || top > 150
        || right > 150
        || bottom > 150
    )
        return

    ; Ignore insignificant differences.
    if (Abs(left) < 2)
        left := 0

    if (Abs(top) < 2)
        top := 0

    if (Abs(right) < 2)
        right := 0

    if (Abs(bottom) < 2)
        bottom := 0

    signature := left "|" top "|" right "|" bottom

    if !LearnedOffsets.Has(process)
    {
        LearnedOffsets[process] := {
            Signature: signature,
            Count: 1
        }
        return
    }

    learned := LearnedOffsets[process]

    ; Restart learning if the measured signature changes.
    if (learned.Signature != signature)
    {
        learned.Signature := signature
        learned.Count := 1
        LearnedOffsets[process] := learned
        return
    }

    learned.Count++
    LearnedOffsets[process] := learned

    ; Apply the offsets only after three identical measurements.
    if (learned.Count < 3)
        return

    data := Programs[process]

    changed := false

    if (data.OffsetLeft != left)
    {
        data.OffsetLeft := left
        changed := true
    }

    if (data.OffsetTop != top)
    {
        data.OffsetTop := top
        changed := true
    }

    if (data.OffsetRight != right)
    {
        data.OffsetRight := right
        changed := true
    }

    if (data.OffsetBottom != bottom)
    {
        data.OffsetBottom := bottom
        changed := true
    }

    if changed
    {
        Programs[process] := data

        ; Reset the learning state after successful calibration.
        if LearnedOffsets.Has(process)
            LearnedOffsets.Delete(process)

        MarkSettingsForSave()
    }
}

; ----------------------------------------------------------
; Returns true if the specified program already has calibrated
; viewport offsets.
; ----------------------------------------------------------
HasCalibrated(process)
{
    global Programs

    if !Programs.Has(process)
        return false

    data := Programs[process]

    return (
        HasProp(data, "OffsetTop")
        && HasProp(data, "OffsetBottom")
        && HasProp(data, "OffsetLeft")
        && HasProp(data, "OffsetRight")
        && (
            data.OffsetTop != 0
            || data.OffsetBottom != 0
            || data.OffsetLeft != 0
            || data.OffsetRight != 0
        )
    )
}

; ==========================================================
; CALIBRATION
; ==========================================================

QueueCalibration(process, parentViewport, childViewport)
{
    global PendingCalibration

    PendingCalibration[process] := {
        Parent: parentViewport,
        Child: childViewport
    }

    SetTimer(CalibrationTimer.Bind(process), -250)
}

CalibrationTimer(process)
{
    global PendingCalibration

    if !PendingCalibration.Has(process)
        return

    data := PendingCalibration[process]
    PendingCalibration.Delete(process)

    CalibrateOffsets(
        process,
        data.Parent,
        data.Child
    )
}


; ==========================================================
; WINDOW VALIDATION
; ==========================================================

IsMainWindow(hwnd)
{
    ; Verify that the window still exists.
    if !hwnd || !DllCall("IsWindow", "Ptr", hwnd)
        return false

    ; Ignore invisible windows.
    if !DllCall("IsWindowVisible", "Ptr", hwnd)
        return false

    try
    {
        style := WinGetExStyle("ahk_id " hwnd)
    }
    catch
    {
        return false
    }

    ; Ignore tool windows (WS_EX_TOOLWINDOW).
    if (style & 0x80)
        return false

    ; Owned windows are usually dialogs and not main windows.
    try
    {
        owner := DllCall("GetWindow", "Ptr", hwnd, "UInt", 4, "Ptr")

        if owner
            return false
    }
    catch
    {
        return false
    }

    try
    {
        title := WinGetTitle("ahk_id " hwnd)
    }
    catch
    {
        return false
    }

    ; Main windows are expected to have a title.
    return (title != "")
}


IsWindowMaximized(hwnd)
{
    ; Verify that the window handle is still valid.
    if !DllCall("IsWindow", "Ptr", hwnd)
        return false

    try
        return WinGetMinMax("ahk_id " hwnd) = 1
    catch
        return false
}


; ==========================================================
; STARTUP WINDOWS
; ==========================================================

SimulateResize(hwnd, process)
{
    global startW, startH
    global startWindowW, startWindowH
    global ResizeStart

    ; Verify that the target window still exists.
    if !DllCall("IsWindow", "Ptr", hwnd)
        return false

    ; Verify that the program is configured.
    if !Programs.Has(process)
        return false

    try
    {
        WinGetPos(
            &x,
            &y,
            &winW,
            &winH,
            "ahk_id " hwnd
        )

        data := Programs[process]

        viewport := ViewportResolver.Resolve(
            hwnd,
            process,
            data
        )

        ; Store the original window size.
        startWindowW := winW
        startWindowH := winH

        ; Store the original viewport size.
        startW := viewport.Width
        startH := viewport.Height

        ; Save the initial resize state.
        ResizeStart[hwnd] := {
            WindowX: x,
            WindowY: y,
            WindowW: winW,
            WindowH: winH,
            CenterX: x + Floor(winW / 2),
            CenterY: y + Floor(winH / 2),
            Viewport: viewport
        }
    }
    catch
    {
        return false
    }

    ; Equivalent to EVENT_SYSTEM_MOVESIZEEND.
    FixRatio(hwnd, process)

    return true
}


CheckStartupWindows()
{
    global Programs, CheckedStartupWindows

    for hwnd in WinGetList()
    {
        ; Process only valid top-level application windows.
        if !IsMainWindow(hwnd)
            continue

        ; Skip windows that have already been processed.
        if CheckedStartupWindows.Has(hwnd)
            continue

        try
            process := WinGetProcessName("ahk_id " hwnd)
        catch
            continue

        ; Ignore applications that are not configured.
        if !Programs.Has(process)
            continue

        data := Programs[process]

        ; Run the initial program analysis if it is still pending.
        if (HasProp(data, "AnalysisPending")
            && data.AnalysisPending)
        {
            ProgramAnalyzer.Start(process)
        }

        ; Apply the aspect ratio once and mark the window as processed.
        if SimulateResize(hwnd, process)
        {
            CheckedStartupWindows[hwnd] := true
        }
    }
}


FixStartupRatio(hwnd, process)
{
    SimulateResize(hwnd, process)
}


; ==========================================================
; SETTINGS GUI
; ==========================================================

SelectWindowArea(*)
{
    global selectedArea

    selectedArea := "WINDOW"

    UpdateAreaButtons()
    MarkSettingsChanged()
}


SelectClientArea(*)
{
    global selectedArea

    selectedArea := "CLIENT"

    UpdateAreaButtons()
    MarkSettingsChanged()
}


UpdateAreaButtons()
{
    global selectedArea
    global areaWindowButton, areaClientButton

    areaWindowButton.Value := (selectedArea = "WINDOW")
    areaClientButton.Value := (selectedArea = "CLIENT")
}


SelectTopLeftPosition(*)
{
    global selectedPosition

    selectedPosition := "TOPLEFT"

    UpdatePositionButtons()
    MarkSettingsChanged()
}


SelectCenterPosition(*)
{
    global selectedPosition

    selectedPosition := "CENTER"

    UpdatePositionButtons()
    MarkSettingsChanged()
}


UpdatePositionButtons()
{
    global selectedPosition
    global positionTopLeftButton, positionCenterButton

    positionTopLeftButton.Value := (selectedPosition = "TOPLEFT")
    positionCenterButton.Value := (selectedPosition = "CENTER")
}


ChangeLanguage(*)
{
    global LanguageDropdown
    global CurrentProgram
    global SettingsDirty
    global OriginalSettings
    global IgnoreControlEvents

    if !IsObject(LanguageDropdown)
        return

    selected := LanguageDropdown.Text

    ; Apply the selected language.
    SetLanguage(selected)

    ; Reload all translated strings.
    LangClearCache()
    CreateTrayMenu()

    ; Reset the current settings state.
    SettingsDirty := false
    CurrentProgram := ""
    OriginalSettings := Map()
    IgnoreControlEvents := false

    ; Recreate the settings window using the new language.
    CloseSettings()
    OpenSettings()
}


CreateSettingsWindow()
{
    global SettingsGui

    SettingsGui := Gui("+AlwaysOnTop", Lang("SettingsWindowTitle"))
    SettingsGui.SetFont("s13", "Segoe UI")
    SettingsGui.OnEvent("Close", CloseSettings)
}


CloseSettings(*)
{
    global SettingsGui, SettingsListView, ProgramImageList

    if SettingsGui
    {
        try
            SettingsGui.Destroy()
    }

    SettingsGui := 0
    SettingsListView := 0

    ; Release the ImageList after the GUI has been destroyed.
    if ProgramImageList
    {
        try
            IL_Destroy(ProgramImageList)
        catch
        {
        }

        ProgramImageList := 0
    }
}


OpenSettings(*)
{
    global Programs, SettingsListView, ProgramImageList, SettingsGui
    global CurrentLanguage, LanguageDropdown
    global DefaultIconIndex, ratioWEdit, ratioHEdit
    global areaWindowButton, areaClientButton, selectedArea
    global positionTopLeftButton, positionCenterButton, selectedPosition
    global ListRowToProgram

    ; Reuse the existing settings window if it is already open.
    if SettingsGui
    {
        try
        {
            SettingsGui.Show()
            WinActivate("ahk_id " SettingsGui.Hwnd)
            return
        }
        catch
        {
            SettingsGui := 0
        }
    }

    CreateSettingsWindow()
    settingsGui := SettingsGui


    ; ======================================================
    ; LEFT COLUMN
    ; ======================================================

    title := settingsGui.AddText("x15 y15", Lang("Programs"))
    title.SetFont("s12 bold", "Segoe UI")


    ; ======================================================
    ; RIGHT COLUMN
    ; ======================================================

    title := settingsGui.AddText("x340 y15", Lang("Settings"))
    title.SetFont("s12 bold", "Segoe UI")


    ; Create the ImageList used by the program list.
    if ProgramImageList
    {
        try
            IL_Destroy(ProgramImageList)
        catch
        {
        }
    }

    ProgramImageList := IL_Create(32, 32, true)
    DefaultIconIndex := IL_Add(ProgramImageList, A_WinDir "\System32\shell32.dll", 1)


    ; ======================================================
    ; PROGRAM LIST
    ; ======================================================

    SettingsListView := settingsGui.AddListView(
        "x15 y40 w310 h400 -Hdr -Multi +VScroll",
        ["Programm"]
    )

    SettingsListView.OnEvent("Click", (*) => ForceListViewScrollbar())

    OnMessage(0x203, KeepListViewSelection) ; WM_LBUTTONDBLCLK
    OnMessage(0x201, KeepListViewSelection) ; WM_LBUTTONDOWN
    OnMessage(0x200, ListViewMouseMove)     ; WM_MOUSEMOVE

    SettingsListView.SetImageList(ProgramImageList)
    SendMessage(0x1000 + 3, 1, ProgramImageList, SettingsListView.Hwnd) ; LVM_SETIMAGELIST

    SettingsListView.SetFont("s12", "Segoe UI")
    SettingsListView.ModifyCol(1, 290)

    ; Populate the program list.
    ListRowToProgram.Clear()

    for name, data in Programs
    {
        icon := GetProgramIcon(data)
        iconIndex := (icon) ? IL_Add(ProgramImageList, icon, 1) : DefaultIconIndex

        row := SettingsListView.Add(
            "Icon" iconIndex,
            DisplayProgramName(name)
        )

        ListRowToProgram[row] := name
    }


    ; ======================================================
    ; SETTINGS
    ; ======================================================

    title := settingsGui.AddText("x340 y65", Lang("AspectRatio"))
    title.SetFont("s10 bold", "Segoe UI")

    ratioWEdit := settingsGui.AddEdit("x340 y90 w60", "16")
    ratioWEdit.OnEvent("Change", MarkSettingsChanged)

    ratioColon := settingsGui.AddText("x405 y90", ":")
    ratioColon.SetFont("s16 bold", "Segoe UI")

    ratioHEdit := settingsGui.AddEdit("x420 y90 w60", "9")
    ratioHEdit.OnEvent("Change", MarkSettingsChanged)

    title := settingsGui.AddText("x340 y145", Lang("Position"))
    title.SetFont("s10 bold", "Segoe UI")

    positionTopLeftButton := settingsGui.AddRadio(
        "x340 y167 w85 h55 +0x1000 Group",
        ""
    )
    AutoButtonFont(positionTopLeftButton, "◰`n" Lang("TopLeft"))

    positionCenterButton := settingsGui.AddRadio(
        "x435 y167 w85 h55 +0x1000",
        ""
    )
    AutoButtonFont(positionCenterButton, "⊙`n" Lang("Center"))

    positionTopLeftButton.OnEvent("Click", SelectTopLeftPosition)
    positionCenterButton.OnEvent("Click", SelectCenterPosition)

    title := settingsGui.AddText("x340 y225", Lang("Area"))
    title.SetFont("s10 bold", "Segoe UI")

    areaWindowButton := settingsGui.AddRadio(
        "x340 y244 w85 h55 +0x1000 Group",
        ""
    )
    AutoButtonFont(areaWindowButton, "🖼`n" Lang("Window"))

    areaClientButton := settingsGui.AddRadio(
        "x435 y244 w85 h55 +0x1000",
        ""
    )
    AutoButtonFont(areaClientButton, "🎬`n" Lang("Content"))

    areaWindowButton.OnEvent("Click", SelectWindowArea)
    areaClientButton.OnEvent("Click", SelectClientArea)


    ; ======================================================
    ; ACTION BUTTONS
    ; ======================================================

    global SaveButton, RemoveButton

    SaveButton := settingsGui.AddButton(
        "x340 y310 w180 h30",
        ""
    )
    AutoControlFont(SaveButton, Lang("Save"))

    RemoveButton := settingsGui.AddButton(
        "x340 y350 w180 h30",
        ""
    )
    AutoControlFont(RemoveButton, Lang("RemoveProgram"))

    addButton := settingsGui.AddButton(
        "x340 y390 w180 h30",
        ""
    )
    AutoControlFont(addButton, Lang("AddProgram"))

    settingsGui.AddText("x340 y430 w180 h2 0x10") ; Separator


    ; ======================================================
    ; LANGUAGE SELECTION
    ; ======================================================

    LanguageDropdown := settingsGui.AddDropDownList(
        "x15 y445 w80",
        [
            "DE",
            "EN",
            "FR",
            "ES",
            "IT",
            "NL",
            "PL",
            "PT-BR",
            "TR",
            "RU",
            "JA",
            "KO",
            "ZH-CN",
            "CS",
            "SV",
            "UK",
            "HU",
            "RO",
            "EL",
            "DA",
            "FI",
            "NO"
        ]
    )

    languages := [
        "DE",
        "EN",
        "FR",
        "ES",
        "IT",
        "NL",
        "PL",
        "PT-BR",
        "TR",
        "RU",
        "JA",
        "KO",
        "ZH-CN",
        "CS",
        "SV",
        "UK",
        "HU",
        "RO",
        "EL",
        "DA",
        "FI",
        "NO"
    ]

    ; Select the currently active language.
    for index, languageCode in languages
    {
        if (languageCode = CurrentLanguage)
        {
            LanguageDropdown.Value := index
            break
        }
    }

    LanguageDropdown.OnEvent(
        "Change",
        ChangeLanguage
    )

    closeButton := settingsGui.AddButton(
        "x340 y440 w180 h30",
        ""
    )
    AutoControlFont(closeButton, Lang("Close"))


    ; ======================================================
    ; EVENTS
    ; ======================================================

    SettingsListView.OnEvent("ItemSelect", LoadSelected)
    SettingsListView.OnEvent("ItemFocus", (*) => ForceListViewScrollbar())

    SaveButton.OnEvent("Click", SaveSelected)
    RemoveButton.OnEvent("Click", RemoveSelected)
    addButton.OnEvent("Click", AddCurrentWindow)
    closeButton.OnEvent("Click", CloseSettings)

    ; Select the first program automatically.
    if (Programs.Count > 0)
    {
        SettingsListView.Modify(1, "Select Focus")
        SetTimer(LoadSelected, -10)
    }

    UpdateRemoveButton()

    hasPrograms := (Programs.Count > 0)

    positionTopLeftButton.Enabled := hasPrograms
    positionCenterButton.Enabled := hasPrograms
    areaWindowButton.Enabled := hasPrograms
    areaClientButton.Enabled := hasPrograms

    UpdateAreaButtons()
    UpdateRatioFields()
    UpdatePositionButtons()

    hasPrograms := (Programs.Count > 0)

    SaveButton.Enabled := false
    RemoveButton.Enabled := hasPrograms

    ratioWEdit.Enabled := hasPrograms
    ratioHEdit.Enabled := hasPrograms

    positionTopLeftButton.Enabled := hasPrograms
    positionCenterButton.Enabled := hasPrograms

    areaWindowButton.Enabled := hasPrograms
    areaClientButton.Enabled := hasPrograms

    ; Disable the settings controls when no programs exist.
    if !hasPrograms
    {
        ratioWEdit.Value := "-"
        ratioHEdit.Value := "-"

        selectedPosition := ""
        selectedArea := ""

        positionTopLeftButton.Value := false
        positionCenterButton.Value := false

        areaWindowButton.Value := false
        areaClientButton.Value := false
    }

    versionText := settingsGui.AddText(
        "x518 y460 w30 Right c808080",
        "V.1.1"
    )
    versionText.SetFont("s10", "Segoe UI")

    settingsGui.Show("w560 h480")

    ForceListViewScrollbar()
}


MarkSettingsChanged(*)
{
    global SettingsDirty, SaveButton, IgnoreControlEvents
    global OriginalSettings
    global ratioWEdit, ratioHEdit, selectedPosition, selectedArea

    ; Ignore events triggered while updating controls programmatically.
    if IgnoreControlEvents
        return

    if (OriginalSettings.Count = 0)
    {
        SettingsDirty := true
    }
    else
    {
        w := ratioWEdit.Value
        h := ratioHEdit.Value

        if !RegExMatch(w, "^\d+$") || !RegExMatch(h, "^\d+$")
		{
			; User is still typing or entered an invalid value.
			; Just mark the settings as modified without converting to Integer().
			SettingsDirty := true
		}
		else
		{
			SettingsDirty :=
			(
				Integer(w) != OriginalSettings["RatioW"]
				|| Integer(h) != OriginalSettings["RatioH"]
				|| selectedPosition != OriginalSettings["Position"]
				|| selectedArea != OriginalSettings["Area"]
			)
		}
    }

    ; Enable the Save button only when changes are pending.
    if IsObject(SaveButton)
        SaveButton.Enabled := SettingsDirty
}


; ==========================================================
; LIST ACTIONS (Top-Level Functions)
; ==========================================================

SaveSelected(*)
{
    global Programs, SettingsListView, ListRowToProgram
    global ratioWEdit, ratioHEdit, selectedPosition, selectedArea
    global OriginalSettings
    global SettingsDirty, CurrentProgram, SaveButton

    row := SettingsListView.GetNext()

    if !row
        return

    selected := ListRowToProgram[row]

    if (!selected || !Programs.Has(selected))
        return

    ; ------------------------------------------------------
    ; Validate user input
    ; ------------------------------------------------------

    if (ratioWEdit.Value = "" || ratioHEdit.Value = "")
    {
        MsgBox(
            Lang("MissingRatioValues")
        )
        return
    }

    if (ratioWEdit.Value = "-" || ratioHEdit.Value = "-")
        return

    if !ValidateRatio(&newW, &newH)
        return

    Programs[selected].RatioW := newW
    Programs[selected].RatioH := newH
    Programs[selected].Position := selectedPosition
    Programs[selected].Area := selectedArea

    SaveSettings()

    ; ------------------------------------------------------
    ; Analyze the program when CLIENT mode is selected
    ; ------------------------------------------------------

    if (selectedArea = "CLIENT")
    {
        hwnd := WinExist("ahk_exe " selected)

        if hwnd
        {
            ProgramAnalyzer.Start(selected)
        }
        else
        {
            Programs[selected].AnalysisPending := true
            SaveSettings()
        }
    }

    CheckedStartupWindows.Clear()
    CheckStartupWindows()

    ; Store the current settings as the new baseline.
    OriginalSettings := Map(
        "RatioW", newW,
        "RatioH", newH,
        "Position", selectedPosition,
        "Area", selectedArea
    )

    SettingsDirty := false
    CurrentProgram := selected

    if IsObject(SaveButton)
        SaveButton.Enabled := false

    ShowStatus(
        Format(
            Lang("ProgramSaved"),
            DisplayProgramName(selected)
        )
    )
}

ValidateRatio(&newW, &newH)
{
    global ratioWEdit, ratioHEdit
    global SettingsGui

    ; Validate that both ratio values contain only numeric characters.
    if !RegExMatch(ratioWEdit.Value, "^\d+$")
    || !RegExMatch(ratioHEdit.Value, "^\d+$")
    {
        if IsObject(SettingsGui)
        {
            WinActivate("ahk_id " SettingsGui.Hwnd)

            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Owner" SettingsGui.Hwnd " Icon!"
            )
        }
        else
        {
            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Icon!"
            )
        }

        return false
    }

    newW := Integer(ratioWEdit.Value)
    newH := Integer(ratioHEdit.Value)

    ; The aspect ratio must consist of positive values.
    if (newW <= 0 || newH <= 0)
    {
        if IsObject(SettingsGui)
        {
            WinActivate("ahk_id " SettingsGui.Hwnd)

            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Owner" SettingsGui.Hwnd " Icon!"
            )
        }
        else
        {
            MsgBox(
                Lang("InvalidRatio"),
                Lang("InvalidInputTitle"),
                "Icon!"
            )
        }

        return false
    }

    return true
}

SaveProgram(program)
{
    global Programs
    global ratioWEdit, ratioHEdit
    global selectedPosition, selectedArea
    global SettingsDirty, CurrentProgram, SaveButton

    if (!program || !Programs.Has(program))
        return

    if !ValidateRatio(&newW, &newH)
        return

    oldArea := Programs[program].Area

    Programs[program].RatioW := newW
    Programs[program].RatioH := newH
    Programs[program].Position := selectedPosition
    Programs[program].Area := selectedArea

    ; Trigger a new analysis when switching to CLIENT mode.
    if (selectedArea = "CLIENT"
        && oldArea != "CLIENT")
    {
        Programs[program].AnalysisPending := true
        Programs[program].AnalysisVersion := 0
    }

    SaveSettings()

    CheckedStartupWindows.Clear()
    CheckStartupWindows()

    SettingsDirty := false
    CurrentProgram := program

    if IsObject(SaveButton)
        SaveButton.Enabled := false

    ShowStatus(
        Format(
            Lang("ProgramSaved"),
            DisplayProgramName(program)
        )
    )
}


RemoveSelected(*)
{
    global Programs, SettingsListView, ListRowToProgram, RemoveButton
    global SettingsDirty, CurrentProgram

    row := SettingsListView.GetNext()

    if !row
        return

    displayName := SettingsListView.GetText(row, 1)

    if (displayName = "")
        return

    selected := ListRowToProgram[row]

    if (!selected || !Programs.Has(selected))
        return

    ; ------------------------------------------------------
    ; Preserve the current selection before removing it.
    ; ------------------------------------------------------

    selectedRow := row

    if (CurrentProgram = selected)
    {
        SettingsDirty := false
        CurrentProgram := ""
    }

    Programs.Delete(selected)

    SaveSettings()
    UpdateRemoveButton()

    ; ------------------------------------------------------
    ; Select the next available program.
    ; ------------------------------------------------------

    if (Programs.Count > 0)
    {
        if (selectedRow > Programs.Count)
            selectedRow := Programs.Count

        RefreshProgramList(selectedRow)
    }
    else
    {
        RefreshProgramList()
    }

    ShowStatus(
        Format(
            Lang("ProgramRemoved"),
            displayName
        )
    )
}

KeepListViewSelection(wParam, lParam, msg, hwnd)
{
    global SettingsListView

    if !IsObject(SettingsListView)
        return

    if (hwnd != SettingsListView.Hwnd)
        return

    ForceListViewScrollbar()

    ; Check whether a list item was clicked.
    Hit := SendMessage(0x1012, 0, 0, hwnd) ; LVM_GETNEXTITEM

    ; If the user clicked the empty area,
    ; restore the current selection.
    MouseGetPos(, , , &ctrl)

    if (ctrl = "SysListView32")
    {
        row := SettingsListView.GetNext()

        if row
        {
            SetTimer(
                () => (
                    SettingsListView.Modify(row, "Select Focus")
                ),
                -10
            )
        }
    }
}

ListViewMouseMove(wParam, lParam, msg, hwnd)
{
    global SettingsListView

    if !IsObject(SettingsListView)
        return

    if (hwnd != SettingsListView.Hwnd)
        return

    ; Keep the ListView scrollbar visible while hovering.
    ForceListViewScrollbar()
}

LoadSelected(*)
{
    global IgnoreControlEvents
    global Programs, SettingsListView, ListRowToProgram
    global CurrentProgram, SettingsDirty
    global ratioWEdit, ratioHEdit, selectedPosition, selectedArea
    global OriginalSettings
    global SettingsGui

    Critical

    IgnoreControlEvents := true

    row := SettingsListView.GetNext()

    if !row
    {
        ; Restore the previous selection if the current selection was lost.
        if (CurrentProgram != "")
        {
            for oldRow, oldName in ListRowToProgram
            {
                if (oldName = CurrentProgram)
                {
                    SettingsListView.Modify(oldRow, "Select Focus")
                    break
                }
            }
        }

        return
    }

    selected := ListRowToProgram[row]

    ; ------------------------------------------------------
    ; Prompt the user to save unsaved changes before switching
    ; to another program.
    ; ------------------------------------------------------

    if (selected != CurrentProgram && SettingsDirty)
    {
        if IsObject(SettingsGui)
        {
            WinActivate("ahk_id " SettingsGui.Hwnd)

            result := MsgBox(
                Format(
                    Lang("UnsavedText"),
                    DisplayProgramName(CurrentProgram)
                ),
                Lang("UnsavedTitle"),
                "YesNoCancel Owner" SettingsGui.Hwnd " Icon!"
            )
        }
        else
        {
            result := MsgBox(
                Format(
                    Lang("UnsavedText"),
                    DisplayProgramName(CurrentProgram)
                ),
                Lang("UnsavedTitle"),
                "YesNoCancel Icon!"
            )
        }

        if (result = "Cancel")
        {
            oldProgram := CurrentProgram

            IgnoreControlEvents := true

            for oldRow, oldName in ListRowToProgram
            {
                if (oldName = oldProgram)
                {
                    SettingsListView.Modify(0, "-Select")
                    SettingsListView.Modify(oldRow, "Select Focus")
                    break
                }
            }

            SetTimer(
                () => RestoreSelectedProgram(oldProgram),
                -200
            )

            SetTimer(
                () => (IgnoreControlEvents := false),
                -250
            )

            SettingsDirty := true

            return
        }

        if (result = "Yes")
            SaveProgram(CurrentProgram)
    }

    if (!selected || !Programs.Has(selected))
        return

    ratioWEdit.Enabled := true
    ratioHEdit.Enabled := true

    data := Programs[selected]

    ; Store the loaded settings as the current baseline.
    OriginalSettings := Map(
        "RatioW", data.RatioW,
        "RatioH", data.RatioH,
        "Position", data.Position,
        "Area", data.Area
    )

    ratioWEdit.Value := data.RatioW
    ratioHEdit.Value := data.RatioH

    selectedPosition := data.Position

    if (selectedPosition = "")
        selectedPosition := "TOPLEFT"

    UpdatePositionButtons()

    selectedArea := data.Area

    if (data.Area = "WINDOW")
        SelectWindowArea()
    else
        SelectClientArea()

    IgnoreControlEvents := false

    SettingsDirty := false
    CurrentProgram := selected

    if IsObject(SaveButton)
        SaveButton.Enabled := false

    ; Keep the selected item visible in the ListView.
    row := SettingsListView.GetNext()

    if row
    {
        SettingsListView.Modify(0, "-Select")
        SettingsListView.Modify(row, "Select Focus")
    }
}

UpdateRemoveButton()
{
    global RemoveButton, Programs
    global positionTopLeftButton, positionCenterButton
    global areaWindowButton, areaClientButton

    enabled := (Programs.Count > 0)

    ; Enable or disable the Remove button.
    if IsObject(RemoveButton)
        RemoveButton.Enabled := enabled

    ; Update the position selection controls.
    if IsObject(positionTopLeftButton)
    {
        positionTopLeftButton.Enabled := enabled

        if !enabled
            positionTopLeftButton.Value := false
    }

    if IsObject(positionCenterButton)
    {
        positionCenterButton.Enabled := enabled

        if !enabled
            positionCenterButton.Value := false
    }

    ; Update the viewport area selection controls.
    if IsObject(areaWindowButton)
    {
        areaWindowButton.Enabled := enabled

        if !enabled
            areaWindowButton.Value := false
    }

    if IsObject(areaClientButton)
    {
        areaClientButton.Enabled := enabled

        if !enabled
            areaClientButton.Value := false
    }
}

UpdateRatioFields()
{
    global ratioWEdit, ratioHEdit, Programs

    if !IsObject(ratioWEdit) || !IsObject(ratioHEdit)
        return

    enabled := (Programs.Count > 0)

    ; Enable or disable the aspect ratio input fields.
    ratioWEdit.Enabled := enabled
    ratioHEdit.Enabled := enabled

    ; Adjust the background color to reflect the enabled state.
    if enabled
    {
        ratioWEdit.Opt("-Background202020")
        ratioHEdit.Opt("-Background202020")
    }
    else
    {
        ratioWEdit.Opt("+Backgroundf9f9f9")
        ratioHEdit.Opt("+Backgroundf9f9f9")
    }
}

ForceListViewScrollbar()
{
    global SettingsListView

    if !IsObject(SettingsListView)
        return

    if !WinExist("ahk_id " SettingsListView.Hwnd)
        return

    ; Keep the vertical scrollbar permanently visible.
    DllCall(
        "ShowScrollBar",
        "Ptr", SettingsListView.Hwnd,
        "Int", 1,      ; SB_VERT
        "Int", true
    )
}

RestoreSelectedProgram(program)
{
    global SettingsListView, ListRowToProgram, CurrentProgram

    ; Restore the previous ListView selection if it is still valid.
    if (CurrentProgram != program)
        return

    for row, name in ListRowToProgram
    {
        if (name = program)
        {
            SettingsListView.Modify(0, "-Select")
            SettingsListView.Modify(row, "Select Focus")
            return
        }
    }
}

RefreshProgramList(selectIndex := 1)
{
    global Programs, SettingsListView, ProgramImageList, DefaultIconIndex
    global ListRowToProgram, RemoveButton

    UpdateRemoveButton()

    if !SettingsListView
        return

    SettingsListView.Delete()
    ListRowToProgram.Clear()

    ; Rebuild the program list.
    for name, data in Programs
    {
        icon := GetProgramIcon(data)
        iconIndex := (icon) ? IL_Add(ProgramImageList, icon, 1) : DefaultIconIndex

        row := SettingsListView.Add(
            "Icon" iconIndex,
            DisplayProgramName(name)
        )

        ListRowToProgram[row] := name
    }

    if (Programs.Count > 0)
    {
        if (selectIndex > Programs.Count)
            selectIndex := Programs.Count

        if (selectIndex < 1)
            selectIndex := 1

        SettingsListView.Modify(selectIndex, "Select Focus")

        SetTimer(LoadSelected, -10)

        ; Force the scrollbar to appear after rebuilding the ListView.
        SetTimer(ForceListViewScrollbar, -30)
    }
    else
    {
        SetTimer(ForceListViewScrollbar, -30)

        selectedPosition := ""
        selectedArea := ""

        if IsObject(positionTopLeftButton)
            positionTopLeftButton.Value := false

        if IsObject(positionCenterButton)
            positionCenterButton.Value := false

        if IsObject(areaWindowButton)
            areaWindowButton.Value := false

        if IsObject(areaClientButton)
            areaClientButton.Value := false

        if IsObject(ratioWEdit)
        {
            ratioWEdit.Value := ""
            ratioWEdit.Enabled := false
        }

        if IsObject(ratioHEdit)
        {
            ratioHEdit.Value := ""
            ratioHEdit.Enabled := false
        }

        UpdateRemoveButton()
        UpdateRatioFields()
    }
}


; ==========================================================
; ADD PROGRAM (NON-BLOCKING)
; ==========================================================

AddCurrentWindow(*)
{
    global Programs

    ; Close an already open selection GUI.
    if WinExist(Lang("SelectWindowTitle"))
    {
        Gui(Lang("SelectWindowTitle")).Destroy()
    }

    selectGui := Gui(
        "+AlwaysOnTop -Caption +ToolWindow +E0x40000",
        Lang("SelectWindowTitle")
    )

    selectGui.BackColor := "202020"

    text := selectGui.AddText(
        "cFFFFFF w300 h80 Center",
        Format(Lang("SelectWindowCountdown"), 10)
    )

    text.SetFont("s14 bold", "Segoe UI")

    selectGui.Show("NA Center")
    WinSetAlwaysOnTop(true, "ahk_id " selectGui.Hwnd)

    state := {
        selectedHwnd: 0,
        attempts: 0,
        gui: selectGui,
        text: text,
        timerRef: 0,
        clickHandler: 0
    }

    state.timerRef := AddCurrentWindowCallback.Bind(state)

    global SelectingWindow
    SelectingWindow := true

    state.clickHandler := SelectClickedWindow.Bind(state)

    Hotkey("~LButton", state.clickHandler, "On")
    SetTimer(state.timerRef, 1000)
}

AddCurrentWindowCallback(state)
{
    ; Ensure that the GUI and text control still exist.
    if (!IsObject(state.gui) || !IsObject(state.text))
        return

    if !WinExist("ahk_id " state.gui.Hwnd)
        return

    state.attempts++

    ; Cancel the operation after 10 seconds.
    if (state.attempts >= 10)
    {
        SetTimer(state.timerRef, 0)

        if (state.clickHandler)
            Hotkey("~LButton", state.clickHandler, "Off")

        state.gui.Destroy()

        ShowStatus(Lang("NoWindowSelected"))
        return
    }

    remaining := 10 - state.attempts

    state.text.Text := Format(
        Lang("SelectWindowCountdown"),
        remaining
    )
}

SelectClickedWindow(state, *)
{
    global SelectingWindow, ScriptPID

    MouseGetPos(, , &hwnd)

    if (!hwnd || hwnd = state.gui.Hwnd)
        return

    ; Ignore invalid windows.
    if !IsMainWindow(hwnd)
        return

    ; Ignore desktop windows.
    try
        class := WinGetClass("ahk_id " hwnd)
    catch
        class := ""

    if (class = "Progman" || class = "WorkerW")
        return

    ; Ignore the script's own process.
    try
        pid := WinGetPID("ahk_id " hwnd)
    catch
        pid := 0

    if (pid = ScriptPID)
        return

    ; Window selection completed successfully.
    SelectingWindow := false

    if (state.clickHandler)
        Hotkey("~LButton", state.clickHandler, "Off")

    SetTimer(state.timerRef, 0)

    state.selectedHwnd := hwnd

    state.gui.Destroy()

    ProcessSelectedWindow(hwnd)
}

ProcessSelectedWindow(selectedHwnd)
{
    global Programs
    global RemoveButton
    global SettingsGui

    try
    {
        process := WinGetProcessName("ahk_id " selectedHwnd)

        processPath := ""

        try
            processPath := WinGetProcessPath("ahk_id " selectedHwnd)
        catch
        {
        }
    }
    catch
    {
        ShowStatus(Lang("ProgramNotDetected"))
        return
    }

    ; Prevent duplicate program entries.
    if Programs.Has(process)
    {
        ShowStatus(
            Format(
                Lang("ProgramAlreadyAdded"),
                DisplayProgramName(process)
            )
        )
        return
    }

    Programs[process] := {
        Path: processPath,
        RatioW: 16,
        RatioH: 9,
        Position: "TOPLEFT",
        Area: "WINDOW",
        OffsetTop: 0,
        OffsetBottom: 0,
        OffsetLeft: 0,
        OffsetRight: 0,
        PreferredClass: "",
        AnalysisPending: false,
        AnalysisVersion: 0
    }

    SaveSettings()

    if IsObject(RemoveButton)
    {
        RemoveButton.Enabled := true
    }

    if IsObject(positionTopLeftButton)
    {
        positionTopLeftButton.Enabled := true
        positionCenterButton.Enabled := true
        areaWindowButton.Enabled := true
        areaClientButton.Enabled := true
    }

    ; Select the newly added program in the list.
    newIndex := 1

    for name in Programs
    {
        if (name = process)
            break

        newIndex++
    }

    RefreshProgramList(newIndex)
    UpdateRatioFields()

    CheckedStartupWindows.Clear()
    CheckStartupWindows()

    ShowStatus(
        Format(
            Lang("ProgramAdded"),
            DisplayProgramName(process)
        )
    )
}

; ==========================================================
; EVENT HOOKS
; ==========================================================

; Create the WinEvent callback function.
callback := CallbackCreate(WinEvent, "F")

; Hook the start of a window move/resize operation.
hookStart := DllCall(
    "SetWinEventHook",
    "UInt", EVENT_SYSTEM_MOVESIZESTART,
    "UInt", EVENT_SYSTEM_MOVESIZESTART,
    "Ptr", 0,
    "Ptr", callback,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0
)

; Hook the end of a window move/resize operation.
hookEnd := DllCall(
    "SetWinEventHook",
    "UInt", EVENT_SYSTEM_MOVESIZEEND,
    "UInt", EVENT_SYSTEM_MOVESIZEEND,
    "Ptr", 0,
    "Ptr", callback,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0
)

; Hook window show events.
hookShow := DllCall(
    "SetWinEventHook",
    "UInt", EVENT_OBJECT_SHOW,
    "UInt", EVENT_OBJECT_SHOW,
    "Ptr", 0,
    "Ptr", callback,
    "UInt", 0,
    "UInt", 0,
    "UInt", 0
)

; Register the cleanup routine for script shutdown.
OnExit(Cleanup)


; ==========================================================
; WINDOW EVENT
; ==========================================================

WinEvent(hWinEventHook, event, hwnd, idObject, idChild, idEventThread, msEventTime)
{
    global startW, startH
    global startWindowW, startWindowH
    global paused, correcting, resizing
    global ResizeStart
    global ProcessCache
    global Programs

    ; ==========================================================
    ; WINDOW / PROGRAM STARTUP
    ; ==========================================================

    if (event = EVENT_OBJECT_CREATE
        || event = EVENT_OBJECT_SHOW)
    {
        if hwnd
        {
            SetTimer(CheckStartupWindows, -300)
        }

        return
    }

    ; ==========================================================
    ; IGNORE STANDARD OBJECT EVENTS
    ; (except CREATE and SHOW events)
    ; ==========================================================

    if (idObject != 0)
        return

    if !hwnd
        return

    if !IsMainWindow(hwnd)
        return

    ; ==========================================================
    ; RESIZE HANDLING
    ; ==========================================================

    if correcting || paused || analyzing
        return

    ; ==========================================================
    ; DETERMINE PROCESS
    ; ==========================================================

    process := ""

    if (ProcessCache.Has(hwnd))
    {
        process := ProcessCache[hwnd]
    }
    else
    {
        try
            process := WinGetProcessName("ahk_id " hwnd)
        catch
            return

        CacheManager.Set(
            ProcessCache,
            hwnd,
            process
        )
    }

    if !Programs.Has(process)
        return

    ; ==========================================================
    ; RESIZE START
    ; ==========================================================

    if (event = EVENT_SYSTEM_MOVESIZESTART)
    {
        resizing := true

        startW := 0
        startH := 0

        try
        {
            WinGetPos(
                ,
                ,
                &startWindowW,
                &startWindowH,
                "ahk_id " hwnd
            )

            data := Programs[process]

            viewport := ViewportResolver.Resolve(
                hwnd,
                process,
                data
            )

            startW := viewport.Width
            startH := viewport.Height

            WinGetPos(
                &startX,
                &startY,
                &startWinW,
                &startWinH,
                "ahk_id " hwnd
            )

            ResizeStart[hwnd] := {
                WindowX: startX,
                WindowY: startY,
                WindowW: startWinW,
                WindowH: startWinH,
                CenterX: startX + Floor(startWinW / 2),
                CenterY: startY + Floor(startWinH / 2),
                Viewport: viewport
            }
        }
        catch
        {
            return
        }

        return
    }


    ; ==========================================================
    ; RESIZE END
    ; ==========================================================

    if (event = EVENT_SYSTEM_MOVESIZEEND)
    {
        resizing := false

        try
        {
            WinGetPos(
                ,
                ,
                &endWindowW,
                &endWindowH,
                "ahk_id " hwnd
            )

            ; Ignore the event if the window size has not changed.
            if (endWindowW = startWindowW
                && endWindowH = startWindowH)
            {
                return
            }

            FixRatio(hwnd, process)
        }
        catch
        {
            return
        }

        return
    }
}


; ==========================================================
; SIZE CALCULATIONS
; ==========================================================

GetClientSize(hwnd, &cw, &ch)
{
    rect := Buffer(16)

    if !DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
        return false

    cw := NumGet(rect, 8, "Int")
    ch := NumGet(rect, 12, "Int")

    return true
}

GetClientRectEx(hwnd, &x, &y, &w, &h)
{
    rect := Buffer(16)

    if !DllCall("GetClientRect", "Ptr", hwnd, "Ptr", rect)
        return false

    w := NumGet(rect, 8, "Int")
    h := NumGet(rect, 12, "Int")

    pt := Buffer(8)

    NumPut("Int", 0, pt, 0)
    NumPut("Int", 0, pt, 4)

    if !DllCall("ClientToScreen", "Ptr", hwnd, "Ptr", pt)
        return false

    x := NumGet(pt, 0, "Int")
    y := NumGet(pt, 4, "Int")

    return true
}

GetWindowSizeFromClient(hwnd, clientW, clientH, &winW, &winH)
{
    style := WinGetStyle("ahk_id " hwnd)
    exStyle := WinGetExStyle("ahk_id " hwnd)

    rect := Buffer(16)

    NumPut("Int", 0, rect, 0)
    NumPut("Int", 0, rect, 4)
    NumPut("Int", clientW, rect, 8)
    NumPut("Int", clientH, rect, 12)

    dpi := DllCall(
        "GetDpiForWindow",
        "Ptr", hwnd,
        "UInt"
    )

    ; Fall back to the legacy API on older Windows versions.
    if (
        !dpi
        || !DllCall(
            "AdjustWindowRectExForDpi",
            "Ptr", rect,
            "UInt", style,
            "Int", false,
            "UInt", exStyle,
            "UInt", dpi
        )
    )
    {
        if !DllCall(
            "AdjustWindowRectEx",
            "Ptr", rect,
            "UInt", style,
            "Int", false,
            "UInt", exStyle
        )
        {
            return false
        }
    }

    winW := NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int")
    winH := NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")

    return true
}


; ==========================================================
; CORRECTION FUNCTIONS
; ==========================================================

CorrectWindowAfterResize(
    hwnd,
    RatioW,
    RatioH,
    targetW,
    targetH,
    centerX := 0,
    centerY := 0
)
{
    try
    {
        WinGetPos(
            &x,
            &y,
            &realW,
            &realH,
            "ahk_id " hwnd
        )
    }
    catch
    {
        return
    }

    ; Nothing to do if the target size has already been applied.
    if (realW = targetW && realH = targetH)
        return

    ; Windows may have enforced a minimum window size.
    ; Continue using the actual size that was applied.

    if (Abs(realW - targetW) > Abs(realH - targetH))
        realH := Round(realW * RatioH / RatioW)
    else
        realW := Round(realH * RatioW / RatioH)

    ; Recenter only if the requested size was applied.
    ; Keep the current position if Windows enforced a minimum size.
    if (
        (realW = targetW && realH = targetH)
        && (centerX || centerY)
    )
    {
        x := Round(centerX - Floor(realW / 2))
        y := Round(centerY - Floor(realH / 2))

        WinMove(
            x,
            y,
            realW,
            realH,
            "ahk_id " hwnd
        )

        return
    }

    ; Preserve the current position when a minimum size was enforced.
    WinMove(
        x,
        y,
        realW,
        realH,
        "ahk_id " hwnd
    )
}

FixClientRatio(
    parentHwnd,
    childHwnd,
    RatioW,
    RatioH,
    PositionMode,
    keepPosition := false
)
{
    global startW, startH

    try
    {
        WinGetPos(
            &px,
            &py,
            &pw,
            &ph,
            "ahk_id " parentHwnd
        )

        WinGetPos(
            ,
            ,
            &cw,
            &ch,
            "ahk_id " childHwnd
        )
    }
    catch
    {
        return
    }

    ; Start with the current client size.
    newChildW := cw
    newChildH := ch

    ; Determine which dimension changed.
    deltaW := Abs(cw - startW)
    deltaH := Abs(ch - startH)

    if (deltaW > deltaH)
        newChildH := Round(cw * RatioH / RatioW)
    else
        newChildW := Round(ch * RatioW / RatioH)

    ; Calculate the window border size.
    borderW := pw - cw
    borderH := ph - ch

    newWindowW := newChildW + borderW
    newWindowH := newChildH + borderH

    ; Store the window center.
    ; The final position is calculated after resizing.
    centerX := 0
    centerY := 0

    if (PositionMode = "CENTER" && !keepPosition)
    {
        centerX := px + Floor(pw / 2)
        centerY := py + Floor(ph / 2)
    }

    if (PositionMode = "CENTER" && !keepPosition)
    {
        px := Round(centerX - Floor(newWindowW / 2))
        py := Round(centerY - Floor(newWindowH / 2))
    }

    ; Skip insignificant size changes.
    if (
        Abs(newWindowW - pw) <= 3
        && Abs(newWindowH - ph) <= 3
    )
    {
        return
    }

    if IsWindowMaximized(parentHwnd)
        return

    global correcting := true

    WinMove(
        px,
        py,
        newWindowW,
        newWindowH,
        "ahk_id " parentHwnd
    )

    WinGetPos(
        &realX,
        &realY,
        &realWindowW,
        &realWindowH,
        "ahk_id " parentHwnd
    )

    ; Check whether Windows enforced a minimum window size.
    if (
        realWindowW != newWindowW
        || realWindowH != newWindowH
    )
    {
        if GetClientSize(
            childHwnd,
            &realClientW,
            &realClientH
        )
        {
            borderW := realWindowW - realClientW
            borderH := realWindowH - realClientH

            if (Abs(realWindowW - newWindowW) > Abs(realWindowH - newWindowH))
                realClientH := Round(realClientW * RatioH / RatioW)
            else
                realClientW := Round(realClientH * RatioW / RatioH)

            WinMove(
                realX,
                realY,
                realClientW + borderW,
                realClientH + borderH,
                "ahk_id " parentHwnd
            )

            ; Read the final window size after Windows applied it.
            ; This allows the position to be centered precisely again.
        }
    }

    {
        correcting := false
    }

    SetTimer(
        () => VerifyRatio(
            parentHwnd,
            WinGetProcessName("ahk_id " parentHwnd),
            true
        ),
        -150
    )
}

CorrectClientRatio(
    hwnd,
    process,
    targetWindowW,
    targetWindowH,
    centerX,
    centerY
)
{
    global correcting
    global Programs

    Sleep(30)

    try
    {
        WinGetPos(
            &realX,
            &realY,
            &realW,
            &realH,
            "ahk_id " hwnd
        )
    }
    catch
    {
        return
    }

    ; centerX and centerY are captured at the start of the resize operation.

    ; Nothing to do if the target size has already been applied.
    if (realW = targetWindowW && realH = targetWindowH)
        return

    if !Programs.Has(process)
        return

    data := Programs[process]

    targetRatio := data.RatioW / data.RatioH

    ; Get the current client size.
    if !GetClientSize(hwnd, &clientW, &clientH)
        return

    newClientW := clientW
    newClientH := clientH

    ; Determine which dimension was limited by Windows.
    if (Abs(realW - targetWindowW) > Abs(realH - targetWindowH))
    {
        ; Minimum width reached → adjust the height.
        newClientH := Round(clientW / targetRatio)
    }
    else
    {
        ; Minimum height reached → adjust the width.
        newClientW := Round(clientH * targetRatio)
    }

    ; Calculate the required window size from the client size.
    if !GetWindowSizeFromClient(
        hwnd,
        newClientW,
        newClientH,
        &newW,
        &newH
    )
    {
        return
    }

    correcting := true

    try
    {
        ; Windows may apply a different size.
        WinMove(
            realX,
            realY,
            newW,
            newH,
            "ahk_id " hwnd
        )

        ; Read back the actual window size.
        WinGetPos(
            &realX,
            &realY,
            &realW,
            &realH,
            "ahk_id " hwnd
        )

        ; Recenter only in CENTER mode and only if the
        ; requested size was applied successfully.
        if (
            (realW = targetWindowW && realH = targetWindowH)
            && (centerX || centerY)
        )
        {
            realX := Round(centerX - Floor(realW / 2))
            realY := Round(centerY - Floor(realH / 2))

            WinMove(
                realX,
                realY,
                ,
                ,
                "ahk_id " hwnd
            )
        }
    }
    finally
    {
        correcting := false
    }
}


; ==========================================================
; MAIN RATIO CORRECTION
; ==========================================================

FixRatio(hwnd, process, keepPosition := false)
{
    global Programs, startW, startH, startWindowW, startWindowH
	global ResizeStart
	global correcting, paused, resizing
	wasMaximized := false
	; Ignore correction while paused or during an active resize operation.																	  
    if paused || resizing
        return
		; Verify that the window still exists.								  
	    if !DllCall("IsWindow", "Ptr", hwnd)
        return
	; Skip unknown programs or recursive corrections.												 
	if (!Programs.Has(process) || correcting)
		return
	; Ensure all required settings exist for this program.													  
	EnsureProgramDefaults(process)
	data := Programs[process]
	if !IsObject(data)
    return
	; Restore missing resize start values if necessary.												   
    if (startWindowW = 0 || startWindowH = 0)
        WinGetPos(, , &startWindowW, &startWindowH, "ahk_id " hwnd)
    RatioW := Max(1, data.RatioW)
    RatioH := Max(1, data.RatioH)
    PositionMode := data.Position
    AreaMode := data.Area
	; Resolve the active viewport.							  
	viewport := ViewportResolver.Resolve(hwnd, process, data)
	child := (viewport.Source = "CHILD") ? viewport.Hwnd : 0
	wasMaximized := IsWindowMaximized(hwnd)
    try
    {
        WinGetPos(&oldX, &oldY, &w, &h, "ahk_id " hwnd)
    }
    catch
    {
        return
    }
    x := oldX
    y := oldY
    ; Determine the initial viewport size.
    if (startW = 0 || startH = 0)
	{
		startW := viewport.Width
		startH := viewport.Height
		if (startW <= 0 || startH <= 0)
			return
	}
    ; ==================================================
    ; WINDOW MODE
    ; ==================================================
    if (AreaMode = "WINDOW")
    {
        newW := w
        newH := h
        deltaW := Abs(w - startWindowW)
        deltaH := Abs(h - startWindowH)
        ; Fallback if the resize start event was not detected.
        if (startWindowW = 0 || startWindowH = 0)
        {
            if (w / h > RatioW / RatioH)
            {
                deltaW := 10
                deltaH := 0
            }
            else
            {
                deltaW := 0
                deltaH := 10
            }
        }
		; Adjust the dimension that was not actively resized.													 
        if (deltaW > deltaH)
            newH := Round(w * RatioH / RatioW)
        else
            newW := Round(h * RatioW / RatioH)
        ; Store the current window center.
		; The final position is calculated after resizing.
		centerX := 0
		centerY := 0
		if (PositionMode = "CENTER")
		{
			centerX := oldX + Floor(w / 2)
			centerY := oldY + Floor(h / 2)
		}

		; Keep the original position during the initial resize.
		x := oldX
		y := oldY
        ; Skip insignificant size differences.
        if (Abs(newW - w) <= 1 && Abs(newH - h) <= 1)
            return
        try
		{
			DllCall(
				"SetWindowPos",
				"ptr", hwnd,
				"ptr", 0,
				"int", x,
				"int", y,
				"int", newW,
				"int", newH,
				"uint", 0x0004 ; SWP_NOZORDER
			)
			; Read the actual size accepted by Windows.
			WinGetPos(&realX, &realY, &realW, &realH, "ahk_id " hwnd)
			; Re-center only if Windows accepted the requested size.
			if (PositionMode = "CENTER"
				&& realW = newW
				&& realH = newH)
			{
				realX := Round(centerX - Floor(realW / 2))
				realY := Round(centerY - Floor(realH / 2))

				WinMove(realX, realY,,, "ahk_id " hwnd)
			}
			CorrectWindowAfterResize(
				hwnd,
				RatioW,
				RatioH,
				newW,
				newH,
				centerX,
				centerY
			)
			SetTimer(() => VerifyRatio(hwnd, process, true), -150)
		}
		catch
		{
		}
        return
    }
        ; ==================================================
		; CLIENT MODE
		; ==================================================
		clientW := viewport.Width
		clientH := viewport.Height
		if (clientW <= 0 || clientH <= 0)
			return
		; Use the dedicated child window correction when available.
		if (AreaMode = "CLIENT" && child)
		{
			FixClientRatio(hwnd, child, RatioW, RatioH, PositionMode, keepPosition)
			return
		}
		; Client mode without a dedicated child viewport.
		newClientW := clientW
		newClientH := clientH
		deltaClientW := Abs(clientW - startW)
		deltaClientH := Abs(clientH - startH)
		; Fallback if the resize start event was not detected.
		if (startW = 0 || startH = 0)
		{
			if (clientW / clientH > RatioW / RatioH)
			{
				deltaClientW := 10
				deltaClientH := 0
			}
			else
			{
				deltaClientW := 0
				deltaClientH := 10
			}
		}
		; Adjust the dimension that was not actively resized.
		if (deltaClientW > deltaClientH)
			newClientH := Round(clientW * RatioH / RatioW)
		else
			newClientW := Round(clientH * RatioW / RatioH)
		; Convert the target client size to the required window size.
		if !GetWindowSizeFromClient(hwnd, newClientW, newClientH, &newW, &newH)
			return
		; Store the current window center.
		centerX := 0
		centerY := 0
		if (PositionMode = "CENTER")
		{
			centerX := oldX + Floor(w / 2)
			centerY := oldY + Floor(h / 2)
		}

		; Keep the original position during the initial resize.
		x := oldX
		y := oldY
		; Skip insignificant size differences.
		if (Abs(newW - w) <= 1 && Abs(newH - h) <= 1)
			return
		correcting := true
	try
	{
		; Apply the initial window resize.
		WinMove(x, y, newW, newH, "ahk_id " hwnd)
		if wasMaximized
			WinMaximize("ahk_id " hwnd)
	}
	catch
	{
	}
	finally
	{
		correcting := false
	}
		; Read the actual size accepted by Windows.
		WinGetPos(&realX, &realY, &realW, &realH, "ahk_id " hwnd)
		
		; Re-center only if Windows accepted the requested size.
		if (PositionMode = "CENTER"
			&& realW = newW
			&& realH = newH)
		{
			realX := Round(centerX - Floor(realW / 2))
			realY := Round(centerY - Floor(realH / 2))

			WinMove(realX, realY,,, "ahk_id " hwnd)
		}
		
		; Schedule a secondary correction if Windows enforced a minimum size.
		if (realW != newW || realH != newH)
		{
			SetTimer(
				() => CorrectClientRatio(
					hwnd,
					process,
					newW,
					newH,
					0,
					0
				),
				-30
			)
		}
		
		; Verify the final aspect ratio.
		SetTimer(() => VerifyRatio(hwnd, process, true), -150)

		; Perform a second verification after any Windows minimum-size adjustment.
		SetTimer(() => RecheckClientRatio(hwnd, process), -300)
}


; ==========================================================
; RATIO VERIFICATION
; ==========================================================

VerifyRatio(hwnd, process, refresh := false)
{
    global Programs, correcting, verifying, RATIO_TOLERANCE
    global resizing

    ; Prevent recursive verification or correction.
    if verifying || correcting || resizing
        return

    verifying := true

    try
    {
        ; Ignore unknown programs.
        if !Programs.Has(process)
            return

        ; Allow Windows to finish applying the resize before measuring.
        if (refresh)
        {
            Sleep(30)

            try
                WinGetPos(, , &dummyW, &dummyH, "ahk_id " hwnd)
            catch
                return
        }

        data := Programs[process]

        ; Resolve the current viewport.
        viewport := ViewportResolver.Resolve(hwnd, process, data)

        w := viewport.Width
        h := viewport.Height

        if (w <= 0 || h <= 0)
            return

        currentRatio := w / h
        targetRatio := data.RatioW / data.RatioH
        difference := Abs(currentRatio - targetRatio)

        ; Correct the window if the ratio exceeds the allowed tolerance.
        if (difference > RATIO_TOLERANCE)
        {
            if (data.Area = "CLIENT")
            {
                ViewportResolver.HandleClientFailure(
                    hwnd,
                    process
                )

                return
            }

            FixRatio(hwnd, process)
        }
        else
        {
            ; Reset the client failure counter after a successful verification.
            ViewportResolver.ResetClientFailures(process)
        }
    }
    finally
    {
        verifying := false
    }
}

RecheckClientRatio(hwnd, process)
{
    global Programs

    ; Ignore unknown programs.
    if !Programs.Has(process)
        return

    data := Programs[process]

    ; Only applicable in CLIENT mode.
    if (data.Area != "CLIENT")
        return

    try
    {
        viewport := ViewportResolver.Resolve(hwnd, process, data)
    }
    catch
    {
        return
    }

    if (viewport.Width <= 0 || viewport.Height <= 0)
        return

    currentRatio := viewport.Width / viewport.Height
    targetRatio := data.RatioW / data.RatioH

    ; Perform a second correction if Windows changed the client size.
    if (Abs(currentRatio - targetRatio) > RATIO_TOLERANCE)
    {
        ; Ignore previous resize start values.
        global startW, startH

        startW := viewport.Width
        startH := viewport.Height

        FixRatio(hwnd, process, true)
    }
}


; ==========================================================
; TRAY FUNCTIONS
; ==========================================================

TrayClick(wParam, lParam, msg, hwnd)
{
    ; Open the settings window on tray icon double-click.
    if (lParam = 0x0203)
        OpenSettings()
}

TogglePause(*)
{
    global paused, ConfigFile, IconFile, PauseIconFile
    global StartupWindows, CheckedStartupWindows

    ; Toggle the paused state.
    paused := !paused

    if paused
    {
        ; Clear startup tracking while paused.
        StartupWindows.Clear()
        CheckedStartupWindows.Clear()
    }
    else
    {
        ; Reset startup tracking and rescan existing windows.
        StartupWindows.Clear()
        CheckedStartupWindows.Clear()

        SetTimer(CheckStartupWindows, 100)
    }

    ; Persist the current pause state.
    IniWrite(paused ? 1 : 0, ConfigFile, "General", "Paused")

    ; Update the tray icon.
    if (paused && FileExist(PauseIconFile))
        TraySetIcon(PauseIconFile)
    else if FileExist(IconFile)
        TraySetIcon(IconFile)

    ; Update the tray menu entry.
    if paused
    {
        try
            A_TrayMenu.Rename("Ratio-Lock pausieren", "Ratio-Lock fortsetzen")
        catch
        {
        }
    }
    else
    {
        try
            A_TrayMenu.Rename("Ratio-Lock fortsetzen", "Ratio-Lock pausieren")
        catch
        {
        }
    }
}

EnableStartup(*)
{
    taskName := "WindowRatioLock"
    scriptPath := A_ScriptFullPath

    ; Create a scheduled task that starts the script with elevated privileges.
    cmd := 'schtasks /Create '
        . '/TN "' taskName '" '
        . '/TR "\"' scriptPath '\"" '
        . '/SC ONLOGON '
        . '/RL HIGHEST '
        . '/F'

    result := RunWait(A_ComSpec " /c " cmd, , "Hide")

    if (result != 0)
    {
        ShowStatus(Lang("AutostartFailed"))
        return
    }

    ShowStatus(Lang("AutostartEnabled"))

    Sleep(1500)
    Reload()
}

StartupEnabled()
{
    taskName := "WindowRatioLock"

    ; Check whether the scheduled startup task exists.
    cmd := 'schtasks /Query /TN "' taskName '"'

    result := RunWait(A_ComSpec " /c " cmd, , "Hide")

    return result = 0
}

DisableStartup(*)
{
    taskName := "WindowRatioLock"

    ; Remove the scheduled startup task.
    cmd := 'schtasks /Delete /TN "' taskName '" /F'

    RunWait(A_ComSpec " /c " cmd, , "Hide")

    ShowStatus(Lang("AutostartDisabled"))

    Sleep(1500)
    Reload()
}

ExitScript(*)
{
    ; Terminate the script.
    ExitApp()
}


; ==========================================================
; CLEANUP
; ==========================================================

Cleanup(*)
{
    global hookStart, hookEnd, callback
    global StatusGui, SettingsGui, ProgramImageList
    global CheckedStartupWindows

    ; Clear runtime caches.
    try
        ProcessCache.Clear()
    catch
    {
    }

    try
        ChildCache.Clear()
    catch
    {
    }

    try
        CheckedStartupWindows.Clear()
    catch
    {
    }

    ; Unregister all window event hooks.
    if hookStart
        DllCall("UnhookWinEvent", "Ptr", hookStart)

    if hookEnd
        DllCall("UnhookWinEvent", "Ptr", hookEnd)

    ; Release the WinEvent callback.
    if callback
        CallbackFree(callback)

    ; Destroy the status window.
    if IsObject(StatusGui)
        try
            StatusGui.Destroy()
    catch
    {
    }

    ; Destroy the settings window.
    if IsObject(SettingsGui)
        try
            SettingsGui.Destroy()
    catch
    {
    }

    ; Release the program icon image list.
    if ProgramImageList
    {
        try
            IL_Destroy(ProgramImageList)
        catch
        {
        }
    }
}
