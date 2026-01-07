/**
 * StudioView - The all-in-one default view
 * Contains transport, timeline, mixer, regions - everything a solo musician needs
 */

import { useState, useEffect, type ReactElement } from 'react';
import {
  RecordingActionsBar,
  MetronomeButton,
  TapTempoButton,
  TimeSignatureButton,
  CollapsibleSection,
  ProjectSection,
  Toolbar,
  ToolbarHeaderControls,
  TimelineSection,
  TimelineHeaderControls,
  MixerSection,
} from '../../components';
import { ToastContainer, useToast } from '../../components/Toast';
import { useReaperStore, type SectionId } from '../../store';

export function StudioView(): ReactElement {
  const {
    sections,
    showRecordingActions,
    toggleSection,
    loadLayoutFromStorage,
  } = useReaperStore();
  const { toasts, dismissToast, showUndo, showRedo } = useToast();

  // Detect mobile (for RecordingActionsBar positioning)
  const [isMobile, setIsMobile] = useState(() => window.innerWidth <= 768);

  useEffect(() => {
    const handleResize = () => setIsMobile(window.innerWidth <= 768);
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  // Load layout from storage on mount
  useEffect(() => {
    loadLayoutFromStorage();
  }, [loadLayoutFromStorage]);

  // Get sorted section IDs based on order
  const sectionIds: SectionId[] = ['project', 'toolbar', 'timeline', 'mixer'];
  const sortedSectionIds = [...sectionIds].sort(
    (a, b) => sections[a].order - sections[b].order
  );

  return (
    <div data-view="studio" className="min-h-screen bg-gray-950 text-white p-4">
      {/* Header: Tempo controls (ConnectionStatus moved to global App.tsx) */}
      <header className="flex items-center justify-end mb-4 pr-8">
        <div className="flex items-center gap-3">
          <MetronomeButton />
          <TapTempoButton />
          <TimeSignatureButton />
        </div>
      </header>

      {/* Recording Quick Actions - desktop/tablet only (mobile renders in App.tsx with fixed positioning) */}
      {!isMobile && showRecordingActions && <RecordingActionsBar className="mb-6" />}

      {/* Collapsible Sections - rendered in order */}
      {sortedSectionIds.map((sectionId) => {
        const config = sections[sectionId];

        // Map section IDs to components and controls
        const sectionContent = {
          project: <ProjectSection onUndo={showUndo} onRedo={showRedo} />,
          toolbar: <Toolbar />,
          timeline: <TimelineSection />,
          mixer: <MixerSection />,
        }[sectionId];

        const headerControls = {
          project: undefined,
          toolbar: <ToolbarHeaderControls />,
          timeline: <TimelineHeaderControls />,
          mixer: undefined, // Mixer renders its controls inside the section content
        }[sectionId];

        const title = {
          project: 'Project',
          toolbar: 'Toolbar',
          timeline: 'Timeline',
          mixer: 'Mixer',
        }[sectionId];

        return (
          <CollapsibleSection
            key={sectionId}
            id={sectionId}
            title={title}
            collapsed={config.collapsed}
            onToggle={() => toggleSection(sectionId)}
            headerControls={headerControls}
          >
            {sectionContent}
          </CollapsibleSection>
        );
      })}

      {/* Footer - at bottom of content, visible when scrolled down */}
      <footer className="mt-8 text-center text-gray-600 text-sm">
        REAmo - REAPER Web Control
      </footer>

      {/* Toast notifications for undo/redo feedback */}
      <ToastContainer toasts={toasts} onDismiss={dismissToast} />
    </div>
  );
}
